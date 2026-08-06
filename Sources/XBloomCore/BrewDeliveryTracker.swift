import Foundation

/// Turns the machine's cumulative counters into the amount delivered during the
/// current session, and refuses to believe physically impossible jumps.
///
/// Two things used to push the live figures straight to the end of the recipe:
/// a report that is not poured water at all (the machine-info frame carries the
/// tank level), and a stale counter read before the new program zeroed it.
/// Because the displayed value only ever climbs, one bad reading latched and
/// every later, correct reading was rejected as a regression. Capping each step
/// at what the recipe's fastest pour could physically deliver in the elapsed
/// time keeps a bad reading from moving the UI more than a real pour would,
/// while still letting the display catch up after a gap in telemetry.
public struct BrewDeliveryTracker: Equatable, Sendable {
    public private(set) var delivered: Double = 0

    private let target: Double
    private let maximumRate: Double
    private let allowsCounterReset: Bool
    private let headroom: Double
    private var baseline: Double?
    private var lastRawValue: Double?
    private var lastUpdateAt: Date?

    /// - Parameters:
    ///   - target: The volume or weight the recipe expects to deliver.
    ///   - maximumRate: The fastest the machine could plausibly deliver it, in
    ///     units per second. Usually the recipe's highest pour flow rate.
    ///   - allowsCounterReset: True for counters the machine zeroes when a new
    ///     program starts, such as poured water. False for the scale, whose
    ///     readings are absolute.
    ///   - headroom: How far past the target a reading may still be believed.
    public init(
        target: Double,
        maximumRate: Double,
        allowsCounterReset: Bool,
        headroom: Double = 8
    ) {
        self.target = max(0, target)
        self.maximumRate = max(0.1, maximumRate)
        self.allowsCounterReset = allowsCounterReset
        self.headroom = max(0, headroom)
    }

    public var ceiling: Double { max(target + headroom, target * 1.05) }

    /// Seeds the counter reading that was already on screen before the session
    /// started, so the first live reading is measured as a delta rather than
    /// being taken as the amount delivered so far.
    public mutating func seedBaseline(_ rawValue: Double?, at date: Date = Date()) {
        guard let rawValue, rawValue.isFinite, rawValue >= 0 else { return }
        baseline = rawValue
        lastRawValue = rawValue
        lastUpdateAt = date
    }

    /// Restores a session that is being resumed after the app was closed.
    public mutating func restore(delivered: Double, baseline: Double?) {
        self.delivered = min(ceiling, max(0, delivered))
        if let baseline, baseline.isFinite, baseline >= 0 {
            self.baseline = baseline
        }
    }

    public var currentBaseline: Double? { baseline }

    @discardableResult
    public mutating func ingest(rawValue: Double, at date: Date = Date()) -> Double {
        guard rawValue.isFinite, rawValue >= 0 else { return delivered }

        guard let existingBaseline = baseline else {
            baseline = rawValue
            lastRawValue = rawValue
            lastUpdateAt = date
            return delivered
        }

        // A newly executed program reports the previous brew's total until the
        // machine zeroes the counter. Rebase onto the new counter without
        // discarding what has already been shown. Only a return to zero counts:
        // treating any decrease as a reset let one inflated reading poison the
        // baseline, so every later reading looked like a fresh counter.
        if allowsCounterReset, let lastRawValue, rawValue < 5, lastRawValue >= 5 {
            baseline = rawValue - delivered
        }
        lastRawValue = rawValue

        let reported = max(0, rawValue - (baseline ?? existingBaseline))
        let interval = lastUpdateAt.map { max(0, date.timeIntervalSince($0)) }
        lastUpdateAt = date

        // With no previous reading to measure against — a session resumed after
        // the app was closed — there is no rate to check, so take the machine's
        // figure as it stands.
        let believable: Double
        if let interval {
            // 1.5x leaves room for a machine that runs a little faster than the
            // requested flow rate; the constant keeps very short intervals from
            // freezing the display entirely.
            let maximumStep = maximumRate * interval * 1.5 + 3
            believable = min(reported, delivered + maximumStep)
        } else {
            believable = reported
        }
        delivered = min(ceiling, max(delivered, believable))
        return delivered
    }
}
