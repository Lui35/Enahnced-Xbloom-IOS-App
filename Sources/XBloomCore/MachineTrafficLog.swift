import Foundation

/// A single Bluetooth frame, recorded exactly as it crossed the link.
///
/// The published protocol reference is a clean-room reconstruction from another
/// project's firmware, so any mapping from notification identifiers to brew
/// phases is a hypothesis until this machine's own traffic confirms it.
public struct MachineTrafficEntry: Identifiable, Equatable, Sendable {
    public enum Direction: String, Sendable {
        case sent
        case received
        case unparsed
        case note
    }

    public let id = UUID()
    public let timestamp: Date
    public let direction: Direction
    public let command: UInt16?
    public let detail: String
    public let payloadHex: String

    public init(
        timestamp: Date,
        direction: Direction,
        command: UInt16?,
        detail: String,
        payloadHex: String
    ) {
        self.timestamp = timestamp
        self.direction = direction
        self.command = command
        self.detail = detail
        self.payloadHex = payloadHex
    }

    /// The reference name for this identifier, or an explicit marker that the
    /// machine sent something the reference does not describe.
    public var commandName: String {
        guard let command else { return "—" }
        if let known = XBloomNotification(rawValue: command) {
            return String(describing: known)
        }
        return "unknown(\(command))"
    }
}

/// A bounded recording of everything the machine sent and everything the app
/// sent it, kept so a real brew can be replayed and read afterwards.
public struct MachineTrafficLog: Equatable, Sendable {
    public private(set) var entries: [MachineTrafficEntry] = []
    public private(set) var isRecording = false
    public private(set) var startedAt: Date?

    private let limit: Int

    public init(limit: Int = 4_000) {
        self.limit = max(100, limit)
    }

    public mutating func startRecording(at date: Date = Date()) {
        entries.removeAll(keepingCapacity: true)
        isRecording = true
        startedAt = date
        append(
            MachineTrafficEntry(
                timestamp: date,
                direction: .note,
                command: nil,
                detail: "Recording started",
                payloadHex: ""
            )
        )
    }

    public mutating func stopRecording(at date: Date = Date()) {
        guard isRecording else { return }
        append(
            MachineTrafficEntry(
                timestamp: date,
                direction: .note,
                command: nil,
                detail: "Recording stopped",
                payloadHex: ""
            )
        )
        isRecording = false
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        startedAt = nil
    }

    public mutating func record(
        direction: MachineTrafficEntry.Direction,
        command: UInt16?,
        detail: String,
        payload: Data,
        at date: Date = Date()
    ) {
        guard isRecording else { return }
        append(
            MachineTrafficEntry(
                timestamp: date,
                direction: direction,
                command: command,
                detail: detail,
                payloadHex: Self.hex(payload)
            )
        )
    }

    public mutating func note(_ detail: String, at date: Date = Date()) {
        guard isRecording else { return }
        append(
            MachineTrafficEntry(
                timestamp: date,
                direction: .note,
                command: nil,
                detail: detail,
                payloadHex: ""
            )
        )
    }

    /// A plain-text transcript with a relative timestamp on every line, so the
    /// order and spacing of the machine's events can be read directly.
    public func transcript() -> String {
        let origin = startedAt ?? entries.first?.timestamp ?? Date()
        var lines = [
            "xBloom machine traffic",
            "Recorded: \(ISO8601DateFormatter().string(from: origin))",
            "Frames: \(entries.count)",
            "",
            "  time  dir        id  name                      payload",
        ]
        for entry in entries {
            let offset = entry.timestamp.timeIntervalSince(origin)
            let time = String(format: "%6.2f", offset)
            let direction = entry.direction.rawValue.padding(
                toLength: 9,
                withPad: " ",
                startingAt: 0
            )
            let identifier = entry.command.map(String.init) ?? "-"
            let name = entry.commandName.padding(toLength: 25, withPad: " ", startingAt: 0)
            let detail = entry.detail.isEmpty ? "" : " \(entry.detail)"
            lines.append(
                "\(time)  \(direction) \(identifier.leftPadded(to: 6))  \(name) \(entry.payloadHex)\(detail)"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Every distinct identifier the machine sent, with how many times it
    /// appeared and when it first did. This is what tells us which events the
    /// brew lifecycle can actually be built on.
    public func receivedCommandSummary() -> [(command: UInt16, count: Int, firstOffset: TimeInterval)] {
        let origin = startedAt ?? entries.first?.timestamp ?? Date()
        var counts: [UInt16: (count: Int, first: TimeInterval)] = [:]
        for entry in entries where entry.direction == .received {
            guard let command = entry.command else { continue }
            let offset = entry.timestamp.timeIntervalSince(origin)
            if var existing = counts[command] {
                existing.count += 1
                counts[command] = existing
            } else {
                counts[command] = (1, offset)
            }
        }
        return counts
            .map { (command: $0.key, count: $0.value.count, firstOffset: $0.value.first) }
            .sorted { $0.firstOffset < $1.firstOffset }
    }

    private mutating func append(_ entry: MachineTrafficEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
