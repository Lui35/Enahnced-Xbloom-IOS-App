import Foundation

/// Turns the machine's live scale into the weight of coffee in the cup.
///
/// The scale is an absolute measurement, not a counter, and it was being read
/// through the same monotonic tracker as poured water. That combination is why
/// the yield curve stayed flat while the water curve climbed: the displayed
/// value could only ever rise, so a single disturbance — a hand resting on the
/// machine, the dripper being seated, a knock — ratcheted it above the real
/// weight, and every later, correct reading was then rejected as a regression.
/// A press registered; the coffee never did.
///
/// What this does instead is take the **lowest reading in a short trailing
/// window**. Coffee arrives and stays, so the floor of the window rises with
/// it. A hand pressing down raises the ceiling of the window and never its
/// floor, so it is ignored outright rather than being partly believed and then
/// remembered forever.
public struct ScaleYieldTracker: Equatable, Sendable {
    /// Coffee in the cup, in grams.
    public private(set) var yield: Double = 0
    /// True once the scale has actually reported coffee arriving. A brew where
    /// this stays false has no yield to draw, and the chart should say so
    /// rather than drawing a flat line along zero.
    public private(set) var hasMeasuredYield = false

    /// A transient has to be shorter than this to be rejected. Long enough to
    /// cover a hand steadying the machine, short enough that the curve is not
    /// visibly behind the pour.
    private let window: TimeInterval
    /// Below this the reading is noise around an empty cup rather than coffee.
    private let signalThreshold: Double
    /// The most the cup could plausibly hold for this recipe.
    private let ceiling: Double

    /// The scale reading that counts as zero: the cup, the dripper, and
    /// whatever else is already sitting there.
    private var baseline: Double?
    private var firstReadingAt: Date?
    private struct Reading: Equatable, Sendable {
        var date: Date
        var value: Double
    }

    private var recent: [Reading] = []

    public init(
        expectedYield: Double,
        window: TimeInterval = 1.6,
        signalThreshold: Double = 3,
        headroom: Double = 120
    ) {
        self.window = max(0.2, window)
        self.signalThreshold = max(0, signalThreshold)
        self.ceiling = max(1, expectedYield) + max(0, headroom)
    }

    public var currentBaseline: Double? { baseline }

    /// Seeds the reading that was already on the scale before the session
    /// started.
    public mutating func seedBaseline(_ rawValue: Double?) {
        guard let rawValue, rawValue.isFinite, rawValue >= 0 else { return }
        baseline = rawValue
    }

    /// Re-zeroes on the cup as it stands when the first pour begins.
    ///
    /// The session baseline is taken before grinding, which is before the cup
    /// is necessarily even on the machine. Anything put in place during
    /// preparation would otherwise be counted as coffee. The first pour is the
    /// moment the cup is guaranteed to be where it belongs and still empty.
    public mutating func rebaselineAtExtractionStart() {
        guard let settled = windowFloor() else { return }
        baseline = (baseline ?? 0) + settled
        yield = 0
        hasMeasuredYield = false
        recent.removeAll(keepingCapacity: true)
        firstReadingAt = nil
    }

    /// Restores a session resumed after the app was closed.
    public mutating func restore(yield: Double, baseline: Double?) {
        self.yield = min(ceiling, max(0, yield))
        self.hasMeasuredYield = self.yield >= signalThreshold
        if let baseline, baseline.isFinite, baseline >= 0 {
            self.baseline = baseline
        }
    }

    @discardableResult
    public mutating func ingest(rawValue: Double, at date: Date = Date()) -> Double {
        guard rawValue.isFinite, rawValue >= 0 else { return yield }
        guard let baseline else {
            self.baseline = rawValue
            return yield
        }

        if firstReadingAt == nil { firstReadingAt = date }
        recent.append(Reading(date: date, value: rawValue - baseline))
        let cutoff = date.addingTimeInterval(-window)
        recent.removeAll { $0.date < cutoff }

        // Until a full window has been collected there is nothing to reject a
        // transient with, so nothing is committed yet. Measure that against the
        // first reading ever seen, not against the buffer's oldest survivor:
        // pruning has just dropped everything older than the window, so the
        // survivor is always younger than it and the check never passed.
        guard let firstReadingAt, date.timeIntervalSince(firstReadingAt) >= window,
              let floor = windowFloor() else {
            return yield
        }

        yield = min(ceiling, max(0, floor))
        if yield >= signalThreshold { hasMeasuredYield = true }
        return yield
    }

    private func windowFloor() -> Double? {
        recent.map(\.value).min()
    }
}
