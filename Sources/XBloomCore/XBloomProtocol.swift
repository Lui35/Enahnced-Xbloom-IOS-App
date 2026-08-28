import Foundation

/// Commands the app sends. Every identifier here is present in the official
/// app's own command table; the scale-vibrate pair that used to sit alongside
/// them was not, and the machine had no reason to answer it.
public enum XBloomCommand: UInt16, Sendable {
    case recipeSendAuto = 8001
    case recipeExecute = 8002
    case recipeSendManual = 8004
    case setBypass = 8102
    case setCup = 8104
    case recipeStop = 40519
    /// Pause and resume a running recipe. The vendor's table pairs them, and a
    /// recording of the official app grinding shows `40518` arriving mid-brew,
    /// so the machine does act on the pause half.
    case recipePause = 40518
    case recipeResume = 40524
    /// Sent once on connect by the vendor's app, before anything else. The
    /// machine shows itself as paired afterwards; this app never sent it.
    case mtuNegotiate = 8100
    /// Asks the machine which screen it is on — a read-only probe that moves no
    /// mechanism, so it is safe to use as a connection test.
    case deviceCurrentPage = 8023
    /// Keeps the machine awake for the duration of a session.
    case deviceNoSleep = 8008

    // MARK: Scale
    case inScalePage = 8003
    case outScalePage = 8014
    /// Tare. The PyBloom reference states no tare command exists; the vendor's
    /// own command table has one.
    case weightCleared = 8500

    // MARK: Pages
    /// Leaving a page is how the machine's own app releases a subsystem.
    case outGrinderPage = 8012
    case outBrewerPage = 8013

    // MARK: Grinder
    //
    // A capture of the vendor's app grinding uses only the three below. The
    // 8105/8106/3503 trio this app was built on — size, speed, begin — does
    // not appear once, which is why the grinder screen never turned a burr.

    /// Opens the grinder screen *and* carries the setting: `(size, speed)`.
    /// Not the bare page-open this app assumed. Re-sent on every change.
    case inGrinderPage = 8006
    /// Starts the burr moving: `(1000, size, speed)`. The vendor's table calls
    /// 3500 "adjust" and PyBloom calls it start; the capture settles it, since
    /// every `device_gears` frame follows this command.
    ///
    /// ponytail: the leading 1000 is copied from the capture and its meaning is
    /// unknown — plausibly a dose in centigrams. Revisit if the amount ground
    /// turns out to be wrong.
    case grindAdjust = 3500
    /// Stops a running grind. The vendor sends this, not `grind_end`.
    case grindPause = 8018
    /// Leaves the grinder. Sent when the vendor's app closes the screen.
    case grindEnd = 3505
}

public enum XBloomMachineState: String, Codable, Sendable {
    case disconnected
    case connecting
    case idle
    case grinding
    case brewing
    case paused
    case complete
    case error
}

public struct XBloomTelemetry: Equatable, Sendable {
    public var state: XBloomMachineState
    public var weight: Double?
    public var temperature: Double?
    /// Water the machine reports having poured during the current program.
    public var waterVolume: Double?
    /// How much water is left in the reservoir. This is a completely different
    /// quantity from `waterVolume` and must never be mixed into brew progress.
    public var tankWaterLevel: Double?
    public var waterLevelOK: Bool?
    public var lastCommand: UInt16?
    /// The first four payload bytes of a lifecycle notification, little-endian.
    /// Several of the machine's events carry their meaning here rather than in
    /// the identifier — `wateringPhase` reports which pour is starting, and
    /// `deviceCurrentPage` reports which screen the machine is showing.
    public var eventValue: UInt32?
    /// The machine's raw grinder-progress report. Units are not established, so
    /// it is never presented as grams.
    public var grinderReport: UInt32?
    public var gearPosition: UInt32?

    public init(
        state: XBloomMachineState = .idle,
        weight: Double? = nil,
        temperature: Double? = nil,
        waterVolume: Double? = nil,
        tankWaterLevel: Double? = nil,
        waterLevelOK: Bool? = nil,
        lastCommand: UInt16? = nil,
        eventValue: UInt32? = nil,
        grinderReport: UInt32? = nil,
        gearPosition: UInt32? = nil
    ) {
        self.state = state
        self.weight = weight
        self.temperature = temperature
        self.waterVolume = waterVolume
        self.tankWaterLevel = tankWaterLevel
        self.waterLevelOK = waterLevelOK
        self.lastCommand = lastCommand
        self.eventValue = eventValue
        self.grinderReport = grinderReport
        self.gearPosition = gearPosition
    }
}

public enum XBloomProtocolError: Error, Equatable {
    case malformedPacket
    case invalidCRC
    case valueOutOfRange(String)
}

public enum XBloomProtocol {
    public static let serviceUUID = "0000e0ff-3c17-d293-8e48-14fe2e4da212"
    public static let writeUUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
    public static let notifyUUID = "0000ffe2-0000-1000-8000-00805f9b34fb"
    public static let auxiliaryNotifyUUID = "0000ffe3-0000-1000-8000-00805f9b34fb"

    public static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return crc
    }

    public static func command(
        _ command: XBloomCommand,
        values: [UInt32] = [],
        typeCode: UInt8 = 1,
        deviceID: UInt8 = 1
    ) -> Data {
        var packet = Data([0x58, deviceID, typeCode])
        packet.appendLittleEndian(command.rawValue)
        packet.appendLittleEndian(UInt32(12 + values.count * 4))
        packet.append(0x01)
        values.forEach { packet.appendLittleEndian($0) }
        packet.appendLittleEndian(crc16(packet))
        return packet
    }

    public static func rawCommand(
        _ command: XBloomCommand,
        payload: Data,
        typeCode: UInt8 = 1,
        deviceID: UInt8 = 1
    ) -> Data {
        var packet = Data([0x58, deviceID, typeCode])
        packet.appendLittleEndian(command.rawValue)
        packet.appendLittleEndian(UInt32(12 + payload.count))
        packet.append(0x01)
        packet.append(payload)
        packet.appendLittleEndian(crc16(packet))
        return packet
    }

    /// Final recipe byte: water-to-coffee ratio in tenths.
    public static func recipeRatioByte(for recipe: Recipe) -> UInt8 {
        let ratioTenths = Int((recipe.ratio * 10).rounded(.toNearestOrEven))
        return UInt8(min(255, max(0, ratioTenths)))
    }

    public static func recipePayload(for recipe: Recipe) throws -> Data {
        try RecipeValidator.requireSafe(recipe)
        var body = Data()

        for (index, pour) in recipe.pours.enumerated() {
            var remaining = pour.volume
            repeat {
                let chunk = min(127, remaining)
                body.append(UInt8(chunk))
                body.append(UInt8(pour.temperature))
                body.append(UInt8(pour.pattern.rawValue))
                body.append(vibrationByte(for: pour))
                remaining -= chunk
            } while remaining > 0

            let nextPause = index + 1 < recipe.pours.count ? recipe.pours[index + 1].pauseBefore : 0
            let pause = min(255, pour.pauseAfter + nextPause)
            body.append(UInt8(truncatingIfNeeded: -pause))
            body.append(0)
            body.append(index == 0 ? UInt8(recipe.programRPM.rawValue) : 0)
            body.append(UInt8((pour.flowRate * 10).rounded(.towardZero)))
        }

        guard body.count <= 255 else {
            throw XBloomProtocolError.valueOutOfRange("Recipe payload exceeds 255 bytes.")
        }
        var result = Data([UInt8(body.count)])
        result.append(body)
        result.append(UInt8(recipe.grindSize))

        // PyBloom calls this `total_water`, but the vendor capture settles the
        // field: its recipe pours 165 ml with a 22 g dose and ends in byte 75.
        // 165 / 22 * 10 is exactly 75. Sending the poured volume here is the
        // strongest remaining explanation for the intermittent no-grinder path.
        result.append(recipeRatioByte(for: recipe))
        return result
    }

    public static func brewSequence(for recipe: Recipe) throws -> [Data] {
        let payload = try recipePayload(for: recipe)
        // Read straight off the vendor's own frame for a grinding recipe:
        // 8104 carries (200.0, 80.0). This app sent (90.0, 40.0) — both
        // invented — and the machine, told the cup tops out at 90 for a recipe
        // pouring 168 ml, never moved the burr. A grinder-off brew is left on
        // the pair this machine has already been recorded brewing with.
        let cupMaximum: Float = recipe.useGrinder ? 200 : 90
        let cupMinimum: Float = recipe.useGrinder ? 80 : 0
        // The reference implementation always sends the bean weight here, even
        // when it is not grinding. Sending zero looks like an invalid dose to
        // the machine, which is the likeliest reason a grinder-off recipe was
        // accepted but never started.
        let dose = UInt32(max(0, recipe.dose.rounded(.towardZero)))

        return [
            command(.setBypass, values: [Float(0).bitPattern, Float(0).bitPattern, dose]),
            command(.setCup, values: [cupMaximum.bitPattern, cupMinimum.bitPattern]),
            rawCommand(recipe.useGrinder ? .recipeSendAuto : .recipeSendManual, payload: payload),
            command(.recipeExecute),
        ]
    }

    public static func parseNotification(_ packet: Data) throws -> XBloomTelemetry {
        guard packet.count >= 12 else { throw XBloomProtocolError.malformedPacket }
        let expected = packet.readUInt16LE(at: packet.count - 2)
        guard expected == crc16(packet.dropLast(2)) else { throw XBloomProtocolError.invalidCRC }
        let command = packet.readUInt16LE(at: 3)
        var result = XBloomTelemetry(lastCommand: command)
        if packet.count >= 16 {
            result.eventValue = packet.readUInt32LE(at: 10)
        }

        switch XBloomNotification(rawValue: command) {
        case .weightRealTime:
            result.weight = Double(packet.readFloat32LE(at: 10))
        case .deviceBrewerTemperature:
            result.temperature = Double(packet.readUInt32LE(at: 10)) / 10
        case .brewerVolume:
            result.waterVolume = pouredMilliliters(
                fromMicroliters: Double(packet.readFloat32LE(at: 10))
            )
        case .grinderDoing:
            // The machine's own grinder-progress report. Its units are not
            // established, so it is surfaced raw rather than dressed up as
            // grams.
            result.grinderReport = result.eventValue
            result.state = .grinding
        case .deviceGears, .gearResetZero:
            result.gearPosition = result.eventValue
        case .grindAdjust:
            // The echo of a grind command carries the position the burr carrier
            // is starting from, which is the only way to know where it sits
            // before it begins moving.
            result.gearPosition = result.eventValue
        case .deviceBeginGrinder:
            result.state = .grinding
        case .deviceBeginBrewer, .brewerStart, .wateringPhase:
            result.state = .brewing
        case .deviceBrewerPass, .deviceWateringFinish:
            result.state = .paused
        case .deviceGrinderFinish:
            result.state = .idle
        case .takeCup, .brewerFinish:
            result.state = .complete
        case .grinderEmptyAbnormal:
            result.state = .error
        case .waterTankVolumeLow:
            // Observed mid-brew with a zero payload while the machine carried
            // on pouring normally, so a zero here is a status report and not a
            // fault. Only a non-zero level is treated as a real problem.
            if (result.eventValue ?? 0) != 0 {
                result.state = .error
            }
        case .deviceSyncInfo:
            if packet.count > 46 {
                result.waterLevelOK = packet[43] == 1
                // Reservoir contents, not the amount poured into the dripper.
                result.tankWaterLevel = Double(packet[46])
            }
        default:
            break
        }
        return result
    }

    /// The largest poured volume a Studio recipe can plausibly report.
    public static let maximumPlausibleWaterVolume: Double = 750

    /// Converts the machine's poured-volume counter into milliliters.
    ///
    /// `brewerVolume` is a float32 in **microliters**. This was verified against
    /// a recorded brew of 45 + 95 + 100 ml: the counter plateaued at exactly
    /// 45000 after the bloom and 140000 after the second pour, and its rate of
    /// change matched the recipe's 3.0 ml/s flow.
    ///
    /// Earlier versions guessed at the scale by dividing by ten until the value
    /// fell under a plausible ceiling. That turned the 45 ml bloom into 450 ml,
    /// which is why the display ran straight to the final pour seconds after a
    /// brew began.
    public static func pouredMilliliters(fromMicroliters rawValue: Double) -> Double? {
        guard rawValue.isFinite, rawValue >= 0 else { return nil }
        let milliliters = rawValue / 1_000
        guard milliliters <= maximumPlausibleWaterVolume else { return nil }
        return milliliters
    }

    /// How far `device_gears` counts above the dial it is moving to.
    ///
    /// Three captures end the burr carrier's travel at the requested size plus
    /// exactly thirty: 80 for size 50, 83 for size 53, 81 for size 51. The
    /// offset is the only thing between the machine's gear stream and the
    /// number on the app's own dial.
    static let gearGrindSizeOffset: UInt32 = 30

    /// The grind size the burrs are physically at, from a `device_gears`,
    /// `gear_reset_zero`, or `grind_adjust` echo.
    ///
    /// Nil for a reading outside the dial: the units are only established
    /// across the range three recordings covered, and a stray value must not
    /// paint a position the machine is not at.
    public static func grindSize(atGear gear: UInt32) -> Int? {
        guard gear >= gearGrindSizeOffset else { return nil }
        let size = Int(gear - gearGrindSizeOffset)
        return GrindSizeGuide.fullRange.contains(size) ? size : nil
    }

    private static func vibrationByte(for pour: PourStep) -> UInt8 {
        switch (pour.agitationBefore, pour.agitationAfter) {
        case (false, false): 0
        case (true, false): 1
        case (false, true): 2
        case (true, true): 3
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readFloat32LE(at offset: Int) -> Float {
        Float(bitPattern: readUInt32LE(at: offset))
    }
}
