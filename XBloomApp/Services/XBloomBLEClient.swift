@preconcurrency import CoreBluetooth
import Foundation
import Observation
import XBloomCore

@MainActor
@Observable
final class XBloomBLEClient: NSObject {
    enum ConnectionState: String {
        case unavailable
        case disconnected
        case scanning
        case connecting
        case subscribing
        case connected
    }

    enum DiagnosticState: Equatable {
        case idle
        case testing
        case passed
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var telemetry = XBloomTelemetry(state: .disconnected)
    /// Machine-reported brew lifecycle. This, not the telemetry values, is what
    /// tells the app when grinding ends and extraction actually begins.
    private(set) var brewProgress = BrewProgressTracker()
    private(set) var machineName = "xBloom Studio"
    private(set) var lastError: String?
    private(set) var isSendingRecipe = false
    private(set) var diagnosticState: DiagnosticState = .idle
    private(set) var lastPacketAt: Date?
    private(set) var sentPacketCount = 0
    private(set) var receivedPacketCount = 0
    /// Ground truth for what this machine actually sends. The published
    /// protocol reference describes another project's firmware, so the brew
    /// lifecycle has to be built on identifiers observed here, not assumed.
    private(set) var trafficLog = MachineTrafficLog()

    func startTrafficRecording() {
        trafficLog.startRecording()
        trafficLog.note(
            "Connection \(connectionState.rawValue) · \(machineName)"
        )
    }

    func stopTrafficRecording() {
        trafficLog.stopRecording()
    }

    func clearTrafficLog() {
        trafficLog.clear()
    }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var notifyCharacteristic: CBCharacteristic?
    @ObservationIgnored private var auxiliaryNotifyCharacteristic: CBCharacteristic?
    @ObservationIgnored private var statusNotificationFramer = XBloomNotificationFramer()
    @ObservationIgnored private var auxiliaryNotificationFramer = XBloomNotificationFramer()
    @ObservationIgnored private var connectionAttemptID = UUID()
    @ObservationIgnored private var connectionSetupTask: Task<Void, Never>?
    @ObservationIgnored private var connectionWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var lastBrewActivityAt: Date?
    @ObservationIgnored private var resumeConnectionRequested = false
    @ObservationIgnored private var acknowledgements: [UInt16: Date] = [:]
    /// Armed only after `8002` goes out. It is a core state machine so the BLE
    /// delegate merely transports its decision instead of inventing brew rules.
    @ObservationIgnored private var grinderInterlock: BrewGrinderInterlock?
    /// Machine screens this app has opened and not yet given back. A brew
    /// cannot start on top of one, so `startBrew` leaves them first.
    @ObservationIgnored private var openPages = MachinePages()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool {
        connectionState == .connected
            && peripheral?.state == .connected
            && writeCharacteristic?.properties.contains(.writeWithoutResponse) == true
            && notifyCharacteristic?.isNotifying == true
    }

    var hasLiveMachineResponse: Bool {
        guard let lastPacketAt else { return false }
        return Date().timeIntervalSince(lastPacketAt) < 15
    }

    func connect(resumingBrew: Bool = false) {
        connectionAttemptID = UUID()
        let attemptID = connectionAttemptID
        resumeConnectionRequested = resumingBrew
        lastError = nil
        diagnosticState = .idle
        guard central.state == .poweredOn else {
            connectionState = .unavailable
            lastError = "Turn on Bluetooth to connect to your xBloom."
            return
        }

        if let saved = UserDefaults.standard.string(forKey: "xbloomPeripheralID"),
           let identifier = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(to: known)
            return
        }

        connectionState = .scanning
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self,
                  self.connectionAttemptID == attemptID,
                  self.connectionState == .scanning else { return }
            self.central.stopScan()
            self.connectionState = .disconnected
            self.lastError = "No xBloom was found. Close the official xBloom app, keep the machine awake, and try again."
        }
    }

    func disconnect() {
        connectionAttemptID = UUID()
        connectionSetupTask?.cancel()
        connectionWatchdogTask?.cancel()
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        resetConnection()
    }

    func startBrew(_ recipe: Recipe) async throws {
        guard isConnected else { throw MachineError.notConnected }
        // Nothing may be mid-flight when the recipe goes out.
        await pendingScreenWork?.value
        pendingScreenWork = nil
        try RecipeValidator.requireSafe(recipe)
        let plan = try BrewCommandPlan(recipe: recipe)
        brewProgress.reset()
        grinderInterlock = nil
        trafficLog.note(
            "Brew start · \(recipe.name) · grinder \(recipe.useGrinder ? "on" : "off") · "
                + "\(recipe.pours.count) pours · \(recipe.totalWater) ml · dose \(recipe.dose) g · "
                + "ratio 1:\(String(format: "%.1f", recipe.ratio)) · footer \(XBloomProtocol.recipeRatioByte(for: recipe))"
        )
        isSendingRecipe = true
        defer { isSendingRecipe = false }
        await releaseOpenPages()
        let packetCountBeforeBrew = receivedPacketCount
        var executeSentAt = Date.distantPast

        // This layer only transports the core plan. Packet order, timing, and
        // grinder-first policy live in XBloomCore where recordings can test them.
        for step in plan.steps {
            if step.kind == .execute {
                executeSentAt = Date()
                grinderInterlock = recipe.useGrinder
                    ? BrewGrinderInterlock(requiresGrinding: true)
                    : nil
            }
            do {
                try await write(step.packet)
            } catch {
                if step.kind == .execute { grinderInterlock = nil }
                throw error
            }
            if step.settleAfter > 0 {
                try await Task.sleep(for: .seconds(step.settleAfter))
            }
        }

        let deadline = Date().addingTimeInterval(10)
        while lastBrewActivityAt.map({ $0 < executeSentAt }) ?? true, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard lastBrewActivityAt.map({ $0 >= executeSentAt }) == true else {
            diagnosticState = .failed(
                receivedPacketCount > packetCountBeforeBrew
                    ? "The machine replied, but did not start the recipe. Check its water, cup, dripper, and bean state before trying again."
                    : "The recipe was transmitted, but the machine sent no response. Check the machine before trying again."
            )
            throw MachineError.noMachineResponse
        }
        diagnosticState = .passed
    }

    /// Holds the machine mid-recipe. Unlike a stop, the program stays loaded
    /// and `resumeBrew` picks it up.
    func pauseBrew() throws {
        try writeSimple(.recipePause, note: "Pause requested from the app")
    }

    func resumeBrew() throws {
        try writeSimple(.recipeResume, note: "Resume requested from the app")
    }

    private func writeSimple(_ command: XBloomCommand, note: String) throws {
        guard isConnected, let peripheral, let writeCharacteristic else { throw MachineError.notConnected }
        let packet = XBloomProtocol.command(command)
        peripheral.writeValue(packet, for: writeCharacteristic, type: .withoutResponse)
        sentPacketCount += 1
        trafficLog.note(note)
        trafficLog.record(direction: .sent, command: command.rawValue, detail: "", payload: packet)
    }

    /// Puts a line in the traffic log from the app's own side, so a recording
    /// shows what the app decided as well as what the machine said.
    func noteSessionEvent(_ text: String) {
        trafficLog.note(text)
    }

    func stopBrew() throws {
        grinderInterlock = nil
        guard isConnected, let peripheral, let writeCharacteristic else { throw MachineError.notConnected }
        let packet = XBloomProtocol.command(.recipeStop)
        peripheral.writeValue(packet, for: writeCharacteristic, type: .withoutResponse)
        sentPacketCount += 1
        trafficLog.note("Stop requested from the app")
        trafficLog.record(direction: .sent, command: XBloomCommand.recipeStop.rawValue, detail: "", payload: packet)
    }

    // MARK: - Direct machine tools

    /// Sends one command and waits for the machine to echo it back.
    ///
    /// The echo is the only evidence available that the machine understood a
    /// command whose payload shape has not been verified against a recording,
    /// so every scale and grinder control reports honestly whether it landed.
    @discardableResult
    func send(
        _ command: XBloomCommand,
        values: [UInt32] = [],
        awaitingAcknowledgement: Bool = true,
        timeout: TimeInterval = 2
    ) async throws -> Bool {
        try await sendPacket(
            XBloomProtocol.command(command, values: values),
            command: command.rawValue,
            awaitingAcknowledgement: awaitingAcknowledgement,
            timeout: timeout
        )
    }

    /// Sends either a regular command or a raw recipe packet and waits for the
    /// matching machine echo. Recipe uploads cannot use `send(_:values:)`
    /// because their payload is byte-oriented rather than UInt32 fields.
    private func sendPacket(
        _ packet: Data,
        command: UInt16,
        awaitingAcknowledgement: Bool = true,
        timeout: TimeInterval = 3
    ) async throws -> Bool {
        guard isConnected else { throw MachineError.notConnected }
        let sentAt = Date()
        try await write(packet)
        guard awaitingAcknowledgement else { return true }
        return try await waitForAcknowledgement(command, sentAt: sentAt, timeout: timeout)
    }

    private func waitForAcknowledgement(
        _ command: UInt16,
        sentAt: Date,
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = sentAt.addingTimeInterval(timeout)
        while Date() < deadline {
            if let acknowledged = acknowledgements[command], acknowledged >= sentAt {
                return true
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Gives back every machine screen this app still holds, and lets the
    /// machine settle, before a recipe goes out.
    ///
    /// The screens are opened from views that release them in `onDisappear`,
    /// which is unordered with respect to a brew starting: the exit landed
    /// between the brew's own setup commands, and a recipe sent to grind
    /// poured without grinding. Doing it here, awaited, is the only way the
    /// machine is guaranteed to be off the scale before `8102` arrives.
    private func releaseOpenPages() async {
        guard !openPages.isEmpty else { return }
        let exits = openPages.exitsBeforeBrew
        openPages = MachinePages()
        trafficLog.note("Releasing machine screens before the recipe")
        for exit in exits {
            try? await write(XBloomProtocol.command(exit))
            // Screen transitions need the same full settling interval as recipe
            // setup. Missing an exit echo must never cancel a requested brew.
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Opens the machine's scale screen so its display follows the app.
    @discardableResult
    func openScale() async throws -> Bool {
        trafficLog.note("Scale opened from the app")
        openPages.scale = true
        return try await send(.inScalePage)
    }

    @discardableResult
    func tareScale() async throws -> Bool {
        trafficLog.note("Tare requested")
        return try await send(.weightCleared)
    }

    /// Leaving a screen the app is not on sends a frame the machine did not ask
    /// for, and the one place that costs something is next to a running recipe.
    func closeScale() async {
        guard openPages.scale else { return }
        openPages.scale = false
        trafficLog.note("Scale closed")
        _ = try? await send(.outScalePage, awaitingAcknowledgement: false)
    }

    /// Opens the grinder screen and applies a size and speed.
    @discardableResult
    /// Opens the grinder screen with a setting on it. `8006` is not a bare
    /// page-open: the vendor's app puts the size and speed in it and re-sends
    /// the whole command whenever either changes.
    func prepareGrinder(size: Int, speed: Int) async throws -> Bool {
        trafficLog.note("Grinder prepared · size \(size) · speed \(speed)")
        openPages.grinder = true
        return try await send(
            .inGrinderPage,
            values: [UInt32(max(0, size)), UInt32(max(0, speed))]
        )
    }

    /// Starts the burrs. Every `device_gears` frame in a capture of the
    /// vendor's app follows this command; nothing follows `3503 grind_begin`,
    /// which this app used to send and the vendor never does.
    @discardableResult
    func startGrinding(size: Int, speed: Int) async throws -> Bool {
        trafficLog.note("Grind start requested · size \(size) · speed \(speed)")
        return try await send(
            .grindAdjust,
            values: [1000, UInt32(max(0, size)), UInt32(max(0, speed))]
        )
    }

    @discardableResult
    func stopGrinding() async throws -> Bool {
        trafficLog.note("Grind stop requested")
        return try await send(.grindPause)
    }

    /// Leaves the grinder, in the two steps the vendor's app uses. `3505` ends
    /// the grind and `8012` closes the screen; sending only the first left the
    /// machine sitting on its grinding page after the phone had walked away.
    func closeGrinder() async {
        guard openPages.grinder else { return }
        openPages.grinder = false
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.send(.grindEnd, awaitingAcknowledgement: false)
            try? await Task.sleep(for: .milliseconds(400))
            _ = try? await self.send(.outGrinderPage, awaitingAcknowledgement: false)
        }
        pendingScreenWork = work
        await work.value
    }

    /// Screen changes the app has asked for and not yet seen finish.
    ///
    /// A recipe must never be uploaded while one is in flight. Leaving the
    /// grinder sends two commands 400 ms apart, and a brew started in that gap
    /// dropped an `out_grinder_page` into the middle of the four setup
    /// commands — which is the failure finding 8 already records for the scale.
    private var pendingScreenWork: Task<Void, Never>?

    /// Runs a single pour with no recipe behind it. It travels the same
    /// encoding path a normal brew does, which is the only one verified against
    /// a recording.
    func startManualPour(_ pour: ManualPour) async throws {
        guard pour.validate().isEmpty else {
            throw MachineError.unsafeManualPour(pour.validate().first?.message ?? "")
        }
        try await startBrew(pour.asRecipe)
    }

    func testConnection() async {
        guard isConnected else {
            diagnosticState = .failed(MachineError.notConnected.localizedDescription)
            return
        }
        diagnosticState = .testing
        let packetCountBeforeTest = receivedPacketCount
        do {
            // Asks the machine which screen it is showing. This replaces two
            // scale-vibrate opcodes that are absent from the vendor's command
            // set, so a silent machine used to look like a broken link when the
            // real problem was a command it never recognised. This one also
            // moves nothing.
            try await write(XBloomProtocol.command(.deviceCurrentPage))

            let deadline = Date().addingTimeInterval(3)
            while receivedPacketCount == packetCountBeforeTest, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if receivedPacketCount > packetCountBeforeTest {
                diagnosticState = .passed
            } else {
                diagnosticState = .failed(
                    "No reply arrived. Close the official xBloom app, keep the machine awake, and reconnect."
                )
            }
        } catch {
            diagnosticState = .failed(error.localizedDescription)
        }
    }

    private func connect(to peripheral: CBPeripheral) {
        connectionSetupTask?.cancel()
        connectionWatchdogTask?.cancel()
        central.stopScan()
        self.peripheral = peripheral
        machineName = peripheral.name ?? "xBloom Studio"
        peripheral.delegate = self
        connectionState = .connecting
        telemetry.state = .connecting
        central.connect(peripheral)

        let attemptID = connectionAttemptID
        connectionWatchdogTask = Task { @MainActor [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled,
                  let self,
                  self.connectionAttemptID == attemptID,
                  self.connectionState != .connected else { return }
            if let peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.failConnection("The Bluetooth setup timed out. Keep the xBloom awake, close the official app, and try again.")
        }
    }

    private func resetConnection() {
        connectionSetupTask?.cancel()
        connectionSetupTask = nil
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        auxiliaryNotifyCharacteristic = nil
        statusNotificationFramer.reset()
        auxiliaryNotificationFramer.reset()
        // Screens do not survive the link. Leaving them marked open would make
        // the next brew send exits for pages the machine is no longer on.
        openPages = MachinePages()
        connectionState = .disconnected
        telemetry = XBloomTelemetry(state: .disconnected)
        // A live session keeps its own copy of the phase and pour index, so
        // clearing the tracker here only discards machine state that no longer
        // applies; it never rewinds a brew that is still running.
        brewProgress.reset()
        grinderInterlock = nil
        lastPacketAt = nil
        sentPacketCount = 0
        receivedPacketCount = 0
        lastBrewActivityAt = nil
        diagnosticState = .idle
        resumeConnectionRequested = false
    }

    private func failConnection(_ message: String) {
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        resetConnection()
        lastError = message
    }

    private func finishConnectionSetup() async {
        do {
            if resumeConnectionRequested {
                // Never send stop/quit setup commands while attaching to a
                // recipe that is already running independently on the machine.
                connectionWatchdogTask?.cancel()
                connectionWatchdogTask = nil
                connectionState = .connected
                telemetry.state = .idle
                resumeConnectionRequested = false
                MachineFeedback.machineConnected()
                return
            }
            // Match the vendor connection exactly. It sends 8100 and then lets
            // the machine announce pairing and return home. Unconditional stop
            // and page-exit commands here could perturb the next recipe or stop
            // a program that was already running on the machine.
            let handshakeSentAt = Date()
            try await write(XBloomProtocol.command(.mtuNegotiate, values: [185, 1]))
            guard try await waitForAcknowledgement(
                XBloomCommand.mtuNegotiate.rawValue,
                sentAt: handshakeSentAt,
                timeout: 3
            ) else {
                throw MachineError.commandNotAcknowledged(XBloomCommand.mtuNegotiate.rawValue)
            }
            try await Task.sleep(for: .seconds(1))
            openPages = MachinePages()
            guard !Task.isCancelled else { return }
            connectionWatchdogTask?.cancel()
            connectionWatchdogTask = nil
            connectionState = .connected
            telemetry.state = .idle
            resumeConnectionRequested = false
            MachineFeedback.machineConnected()
        } catch {
            failConnection("The Bluetooth link opened, but machine setup failed: \(error.localizedDescription)")
            diagnosticState = .failed(error.localizedDescription)
        }
    }

    private func write(_ packet: Data) async throws {
        guard let peripheral,
              peripheral.state == .connected,
              let writeCharacteristic,
              writeCharacteristic.properties.contains(.writeWithoutResponse) else {
            throw MachineError.commandChannelUnavailable
        }
        guard packet.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            throw MachineError.packetTooLarge(packet.count)
        }
        while !peripheral.canSendWriteWithoutResponse {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        peripheral.writeValue(packet, for: writeCharacteristic, type: .withoutResponse)
        sentPacketCount += 1
        trafficLog.record(
            direction: .sent,
            command: packet.count >= 5 ? UInt16(packet[3]) | UInt16(packet[4]) << 8 : nil,
            detail: "",
            payload: packet
        )
    }

    private func consumeNotifications(_ data: Data, from characteristicUUID: CBUUID) {
        let statusUUID = CBUUID(string: XBloomProtocol.notifyUUID)
        let isStatusChannel = characteristicUUID == statusUUID
        let packets: [Data]
        if isStatusChannel {
            packets = statusNotificationFramer.ingest(data)
        } else {
            packets = auxiliaryNotificationFramer.ingest(data)
        }

        for packet in packets {
            do {
                let update = try XBloomProtocol.parseNotification(packet)
                receivedPacketCount += 1
                lastPacketAt = Date()
                trafficLog.record(
                    direction: .received,
                    command: update.lastCommand,
                    detail: isStatusChannel ? describe(update) : "FFE3 · not merged",
                    payload: packet
                )
                // The vendor's own app filters FFE3 out of its receive path.
                // Record it for diagnostics, but never let it drive brew state.
                guard isStatusChannel else { continue }
                merge(update)
            } catch {
                // Frames the parser rejects matter most: they are the ones the
                // reference does not describe correctly for this machine.
                trafficLog.record(
                    direction: .unparsed,
                    command: packet.count >= 5 ? UInt16(packet[3]) | UInt16(packet[4]) << 8 : nil,
                    detail: "\(error)",
                    payload: packet
                )
                lastError = "Ignored an invalid Bluetooth notification."
            }
        }
    }

    private func describe(_ update: XBloomTelemetry) -> String {
        var parts: [String] = []
        if let value = update.weight { parts.append(String(format: "weight=%.1fg", value)) }
        if let value = update.temperature { parts.append(String(format: "temp=%.1fC", value)) }
        if let value = update.waterVolume { parts.append(String(format: "water=%.1fml", value)) }
        if let value = update.tankWaterLevel { parts.append(String(format: "tank=%.0f", value)) }
        if let value = update.waterLevelOK { parts.append("tankOK=\(value)") }
        return parts.joined(separator: " ")
    }

    private func merge(_ update: XBloomTelemetry) {
        telemetry.lastCommand = update.lastCommand
        if let value = update.weight { telemetry.weight = value }
        if let value = update.temperature { telemetry.temperature = value }
        if let value = update.waterVolume { telemetry.waterVolume = value }
        if let value = update.tankWaterLevel { telemetry.tankWaterLevel = value }
        if let value = update.waterLevelOK { telemetry.waterLevelOK = value }
        if let value = update.grinderReport { telemetry.grinderReport = value }
        if let value = update.gearPosition { telemetry.gearPosition = value }

        guard let command = update.lastCommand else { return }
        // The machine echoes each command back with the same identifier. That
        // echo is the only confirmation available that it understood a command
        // whose payload shape has not been verified.
        acknowledgements[command] = Date()
        brewProgress.ingest(command: command, value: update.eventValue, at: Date())
        enforceGrinderInterlock(command: command, value: update.eventValue)

        switch XBloomNotification(rawValue: command) {
        case .deviceInGrinder, .deviceInBrewer, .deviceBeginGrinder, .deviceBeginBrewer,
             .deviceGears, .grinderDoing, .brewerStart, .wateringPhase:
            lastBrewActivityAt = Date()
        default:
            break
        }

        switch XBloomNotification(rawValue: command) {
        case .deviceBeginGrinder, .deviceBeginBrewer, .brewerStart, .wateringPhase,
             .deviceBrewerPass, .deviceWateringFinish, .deviceGrinderFinish,
             .takeCup, .brewerFinish, .grinderEmptyAbnormal:
            telemetry.state = update.state
        case .waterTankVolumeLow:
            // Only a non-zero level is a fault; the parser leaves the state
            // untouched otherwise, and a running brew must not be interrupted.
            if update.state == .error { telemetry.state = .error }
        default:
            break
        }
    }

    private func enforceGrinderInterlock(command: UInt16, value: UInt32?) {
        guard var interlock = grinderInterlock else { return }
        let decision = interlock.ingest(command: command, value: value)
        grinderInterlock = interlock

        switch decision {
        case .pourAllowed:
            grinderInterlock = nil
        case .stopUnexpectedPour:
            grinderInterlock = nil
            diagnosticState = .failed(
                "The machine began pouring without running the grinder. The recipe was stopped at the first water event."
            )
            lastError = "The grinder did not run, so the app stopped the unexpected pour."
            do {
                try writeSimple(
                    .recipeStop,
                    note: "Safety interlock · watering started before grinding · stop sent"
                )
            } catch {
                trafficLog.note("Safety interlock could not send stop · \(error.localizedDescription)")
            }
        case .grindingConfirmed:
            trafficLog.note("Grinder-first interlock satisfied · grinder path observed")
        case .observing:
            break
        }
    }

    enum MachineError: LocalizedError {
        case notConnected
        case commandChannelUnavailable
        case packetTooLarge(Int)
        case noMachineResponse
        case commandNotAcknowledged(UInt16)
        case unsafeManualPour(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                "Connect to the xBloom and complete the connection test before sending a recipe."
            case .commandChannelUnavailable:
                "The xBloom command channel is not ready. Disconnect and reconnect the machine."
            case .packetTooLarge(let size):
                "The recipe packet is \(size) bytes and exceeds the negotiated Bluetooth limit."
            case .noMachineResponse:
                "The recipe was sent but the xBloom did not respond. Check whether it started before retrying, then disconnect and reconnect if needed."
            case .commandNotAcknowledged(let command):
                "The xBloom did not acknowledge command \(command), so the recipe was not executed. Reconnect and try again."
            case .unsafeManualPour(let reason):
                reason
            }
        }
    }
}

extension XBloomBLEClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .poweredOn {
                connectionState = .unavailable
                telemetry.state = .disconnected
            } else if connectionState == .unavailable {
                connectionState = .disconnected
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = (
            advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
            ?? ""
        ).uppercased()
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard advertisedName.hasPrefix("XBLOOM")
                || advertisedServices.contains(CBUUID(string: XBloomProtocol.serviceUUID)) else {
            return
        }
        MainActor.assumeIsolated {
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "xbloomPeripheralID")
            connectionState = .subscribing
            peripheral.discoverServices([CBUUID(string: XBloomProtocol.serviceUUID)])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            lastError = error?.localizedDescription ?? "The Bluetooth connection failed."
            resetConnection()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error { lastError = error.localizedDescription }
            let wasConnected = connectionState == .connected
            resetConnection()
            if wasConnected { MachineFeedback.machineDisconnected() }
        }
    }
}

extension XBloomBLEClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                failConnection("Could not discover the xBloom Bluetooth service: \(error.localizedDescription)")
                return
            }
            guard let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: XBloomProtocol.serviceUUID)
            }) else {
                lastError = "Connected device does not expose the xBloom service."
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics(
                [
                    CBUUID(string: XBloomProtocol.writeUUID),
                    CBUUID(string: XBloomProtocol.notifyUUID),
                    CBUUID(string: XBloomProtocol.auxiliaryNotifyUUID),
                ],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                failConnection("Could not discover the xBloom command channels: \(error.localizedDescription)")
                return
            }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case CBUUID(string: XBloomProtocol.writeUUID):
                    if characteristic.properties.contains(.writeWithoutResponse) {
                        writeCharacteristic = characteristic
                    } else {
                        lastError = "The machine command channel does not support write-without-response."
                    }
                case CBUUID(string: XBloomProtocol.notifyUUID):
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case CBUUID(string: XBloomProtocol.auxiliaryNotifyUUID):
                    auxiliaryNotifyCharacteristic = characteristic
                    if characteristic.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                default:
                    break
                }
            }
            if writeCharacteristic == nil || notifyCharacteristic == nil {
                failConnection("The required xBloom command or notification characteristic was not found.")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                failConnection("Could not subscribe to xBloom status: \(error.localizedDescription)")
                return
            }
            guard characteristic.uuid == CBUUID(string: XBloomProtocol.notifyUUID),
                  characteristic.isNotifying,
                  writeCharacteristic != nil else { return }
            connectionSetupTask?.cancel()
            connectionSetupTask = Task { @MainActor [weak self] in
                await self?.finishConnectionSetup()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                lastError = error.localizedDescription
                return
            }
            if let value = characteristic.value,
               (
                   characteristic.uuid == CBUUID(string: XBloomProtocol.notifyUUID)
                       || characteristic.uuid == CBUUID(string: XBloomProtocol.auxiliaryNotifyUUID)
               ) {
                consumeNotifications(value, from: characteristic.uuid)
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Async command writers observe canSendWriteWithoutResponse and resume on their next poll.
    }
}
