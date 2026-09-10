import Foundation

/// Live weighing ends when the user confirms. Replacing beans with a server
/// must never change the captured dose or the readiness of the next step.
public struct DoseWeighingState: Equatable, Sendable {
    public private(set) var liveWeight: Double = 0
    public var adjustment: Double?
    public private(set) var confirmedDose: Double?

    public init() {}

    public var measured: Double { adjustment ?? max(0, liveWeight) }
    public var isBrewable: Bool { measured.isFinite && (5...30).contains(measured) }

    public mutating func ingest(weight: Double) {
        guard weight.isFinite else { return }
        liveWeight = weight
    }

    public mutating func tare() {
        liveWeight = 0
        adjustment = nil
    }

    @discardableResult
    public mutating func confirm() -> Bool {
        guard isBrewable else { return false }
        confirmedDose = measured
        return true
    }

    public mutating func reweigh() {
        confirmedDose = nil
        adjustment = nil
    }
}
