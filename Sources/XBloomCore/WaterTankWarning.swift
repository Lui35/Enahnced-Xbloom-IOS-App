import Foundation

/// Remembers a reported tank fault without guessing litres or treating a
/// missing/zero status payload as proof that the tank is empty.
public struct WaterTankWarning: Equatable, Sendable {
    public private(set) var lastLowReportAt: Date?
    public var needsCheck: Bool { lastLowReportAt != nil }

    public init(lastLowReportAt: Date? = nil) { self.lastLowReportAt = lastLowReportAt }

    public mutating func ingest(command: UInt16?, value: UInt32?, waterLevelOK: Bool? = nil, at date: Date = Date()) {
        switch command.flatMap(XBloomNotification.init(rawValue:)) {
        case .waterTankVolumeLow:
            guard let value else { return }
            lastLowReportAt = value == 0 ? nil : date
        case .deviceSyncInfo:
            // Only an affirmative OK clears a remembered fault. The meaning
            // of a zero-filled/absent machine-info field is not established.
            if waterLevelOK == true { lastLowReportAt = nil }
        default:
            break
        }
    }
}
