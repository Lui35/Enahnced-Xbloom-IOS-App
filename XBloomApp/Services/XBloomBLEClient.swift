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
    private(set) var machineName = "xBloom Studio"
    private(set) var lastError: String?
    private(set) var isSendingRecipe = false
    private(set) var diagnosticState: DiagnosticState = .idle
    private(set) var lastPacketAt: Date?
    private(set) var sentPacketCount = 0
    private(set) var receivedPacketCount = 0

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
        try RecipeValidator.requireSafe(recipe)
        let packets = try XBloomProtocol.brewSequence(for: recipe)
        let packetCountBeforeBrew = receivedPacketCount
        isSendingRecipe = true
        defer { isSendingRecipe = false }
        var executeSentAt = Date.distantPast

        for (index, packet) in packets.enumerated() {
            if index == packets.count - 1 {
                executeSentAt = Date()
            }
            try await write(packet)
            if index < packets.count - 1 {
                let delay: UInt64 = recipe.useGrinder ? 1_000_000_000 : 300_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }

        let deadline = Date().addingTimeInterval(10)
        while lastBrewActivityAt.map({ $0 < executeSentAt }) ?? true, Date() < deadline {
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

    func stopBrew() throws {
        guard isConnected, let peripheral, let writeCharacteristic else { throw MachineError.notConnected }
        peripheral.writeValue(XBloomProtocol.command(.recipeStop), for: writeCharacteristic, type: .withoutResponse)
        sentPacketCount += 1
    }

    func testConnection() async {
        guard isConnected else {
            diagnosticState = .failed(MachineError.notConnected.localizedDescription)
            return
        }
        diagnosticState = .testing
        let packetCountBeforeTest = receivedPacketCount
        do {
            try await write(XBloomProtocol.command(.scaleVibrate))
            try await Task.sleep(for: .milliseconds(450))
            try await write(XBloomProtocol.command(.scaleStop))

            let deadline = Date().addingTimeInterval(3)
            while receivedPacketCount == packetCountBeforeTest, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if receivedPacketCount > packetCountBeforeTest {
                diagnosticState = .passed
            } else {
                diagnosticState = .failed(
                    "No reply arrived. If the scale tray vibrated, commands work but telemetry is silent; otherwise close the official xBloom app and reconnect."
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
        connectionState = .disconnected
        telemetry = XBloomTelemetry(state: .disconnected)
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
                return
            }
            try await write(XBloomProtocol.command(.recipeStop))
            try await Task.sleep(for: .milliseconds(500))
            try await write(XBloomProtocol.command(.brewerQuit))
            try await write(XBloomProtocol.command(.grinderQuit))
            try await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            connectionWatchdogTask?.cancel()
            connectionWatchdogTask = nil
            connectionState = .connected
            telemetry.state = .idle
            resumeConnectionRequested = false
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
    }

    private func consumeNotifications(_ data: Data, from characteristicUUID: CBUUID) {
        let statusUUID = CBUUID(string: XBloomProtocol.notifyUUID)
        let packets: [Data]
        if characteristicUUID == statusUUID {
            packets = statusNotificationFramer.ingest(data)
        } else {
            packets = auxiliaryNotificationFramer.ingest(data)
        }

        for packet in packets {
            do {
                let update = try XBloomProtocol.parseNotification(packet)
                receivedPacketCount += 1
                lastPacketAt = Date()
                merge(update)
            } catch {
                lastError = "Ignored an invalid Bluetooth notification."
            }
        }
    }

    private func merge(_ update: XBloomTelemetry) {
        telemetry.lastCommand = update.lastCommand
        if let value = update.weight { telemetry.weight = value }
        if let value = update.temperature { telemetry.temperature = value }
        if let value = update.waterVolume { telemetry.waterVolume = value }
        if let value = update.waterLevelOK { telemetry.waterLevelOK = value }

        if let command = update.lastCommand,
           [9000, 9001, 9003, 9005, 40502, 40510].contains(command) {
            lastBrewActivityAt = Date()
        }

        switch update.lastCommand {
        case 9003, 9005, 40502, 40510, 9010, 40507, 40511, 40512, 40513, 40517, 40522, 8203, 8204:
            telemetry.state = update.state
        default:
            break
        }
    }

    enum MachineError: LocalizedError {
        case notConnected
        case commandChannelUnavailable
        case packetTooLarge(Int)
        case noMachineResponse

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
            resetConnection()
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
