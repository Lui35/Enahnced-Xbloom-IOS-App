import Foundation

public enum XBloomCommand: UInt16, Sendable {
    case grinderQuit = 8012
    case brewerQuit = 8013
    case recipeSendAuto = 8001
    case recipeExecute = 8002
    case recipeSendManual = 8004
    case setBypass = 8102
    case setCup = 8104
    case scaleVibrate = 2502
    case scaleStop = 2505
    case recipeStop = 40519
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

    public init(
        state: XBloomMachineState = .idle,
        weight: Double? = nil,
        temperature: Double? = nil,
        waterVolume: Double? = nil,
        tankWaterLevel: Double? = nil,
        waterLevelOK: Bool? = nil,
        lastCommand: UInt16? = nil
    ) {
        self.state = state
        self.weight = weight
        self.temperature = temperature
        self.waterVolume = waterVolume
        self.tankWaterLevel = tankWaterLevel
        self.waterLevelOK = waterLevelOK
        self.lastCommand = lastCommand
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
            body.append(index == 0 ? UInt8(recipe.rpm.rawValue) : 0)
            body.append(UInt8((pour.flowRate * 10).rounded(.towardZero)))
        }

        guard body.count <= 255 else {
            throw XBloomProtocolError.valueOutOfRange("Recipe payload exceeds 255 bytes.")
        }
        var result = Data([UInt8(body.count)])
        result.append(body)
        result.append(UInt8(recipe.grindSize))

        // The existing desktop server passes round(total ml / 10), and PyBloom
        // writes that value multiplied by ten into the one-byte recipe footer.
        let waterUnits = Int((Double(recipe.totalWater) / 10).rounded(.toNearestOrEven))
        result.append(UInt8(truncatingIfNeeded: waterUnits * 10))
        return result
    }

    public static func brewSequence(for recipe: Recipe) throws -> [Data] {
        let payload = try recipePayload(for: recipe)
        let cupMaximum: Float = 90
        let cupMinimum: Float = recipe.useGrinder ? 40 : 0
        let dose = recipe.useGrinder ? UInt32(recipe.dose.rounded(.towardZero)) : 0

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

        switch command {
        case 20501:
            result.weight = Double(packet.readFloat32LE(at: 10))
        case 8108:
            result.temperature = Double(packet.readUInt32LE(at: 10)) / 10
        case 40523:
            result.waterVolume = normalizedWaterVolume(
                Double(packet.readFloat32LE(at: 10))
            )
        case 9003:
            result.state = .grinding
        case 9005, 40502, 40510:
            result.state = .brewing
        case 9010:
            result.state = .paused
        case 40507, 40511:
            result.state = .idle
        case 40512, 40513:
            result.state = .complete
        case 40517, 40522, 8203, 8204:
            result.state = .error
        case 40521:
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

    /// Accepts the machine's poured-water counter only when it is a possible
    /// milliliter figure.
    ///
    /// This used to divide the reading by ten until it fell under the limit, on
    /// the theory that some firmware scales the counter. That rescaling fired
    /// mid-brew — 740 stayed 740 while the next reading of 760 became 76 — and
    /// the monotonic live figures then latched onto the pre-collapse value and
    /// jumped to the final pour. An out-of-range reading is now simply ignored,
    /// so a single odd frame costs one sample instead of the whole session.
    public static func normalizedWaterVolume(_ rawValue: Double) -> Double? {
        guard rawValue.isFinite,
              (0...maximumPlausibleWaterVolume).contains(rawValue) else { return nil }
        return rawValue
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
