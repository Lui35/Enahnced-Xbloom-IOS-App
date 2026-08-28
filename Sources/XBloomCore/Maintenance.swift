import Foundation

/// The three services this machine needs, and the rule that says when.
///
/// Each rule is measured against what the machine has actually done since the
/// service was last recorded — grams ground, brews pulled, days elapsed — so a
/// week away from the machine does not make anything fall due.
public enum MaintenanceTask: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Sweeping the grinder chute, dock arm, and drip tray with the brush that
    /// came with the machine.
    case grinderBrush
    /// A packet of grinder cleaning tablets, and the calibration that follows
    /// it — the burrs have been disturbed, so they are set again straight away.
    case grinderTablets
    /// Descaling the water path.
    case descale

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .grinderBrush: "Brush the grinder"
        case .grinderTablets: "Cleaning tablets & calibration"
        case .descale: "Descale the water path"
        }
    }

    /// The rule, in the words it would be explained in.
    public var rule: String {
        switch self {
        case .grinderBrush: "Weekly, in any week the grinder ran"
        case .grinderTablets: "Every 1 kg of beans ground"
        case .descale: "Every 300 brews or 3 months"
        }
    }
}

/// What the machine has done since a service was last recorded.
public struct MaintenanceUsage: Equatable, Sendable {
    /// When the clock started: the recorded service, or the first brew if the
    /// service has never been recorded.
    public var since: Date
    /// Whether `since` is a service that was actually recorded, rather than the
    /// beginning of history standing in for one.
    public var wasServiced: Bool
    /// Beans put through the grinder since `since`, in grams.
    public var groundGrams: Double
    /// Brews finished since `since`, simulations excluded.
    public var brews: Int
    /// The last time the grinder actually ran. Nil if it has not since.
    public var lastGrinderUseAt: Date?

    public init(
        since: Date,
        wasServiced: Bool = false,
        groundGrams: Double = 0,
        brews: Int = 0,
        lastGrinderUseAt: Date? = nil
    ) {
        self.since = since
        self.wasServiced = wasServiced
        self.groundGrams = groundGrams
        self.brews = brews
        self.lastGrinderUseAt = lastGrinderUseAt
    }
}

public struct MaintenanceStatus: Equatable, Sendable {
    public var task: MaintenanceTask
    public var isDue: Bool
    /// How far through the interval this service is, 0–1. Reaching 1 is what
    /// makes it due.
    public var progress: Double
    /// The rule with this machine's own numbers in it.
    public var summary: String
    /// True when nothing has happened that this service is measured against —
    /// an unused grinder needs no brush.
    public var isDormant: Bool
}

public enum Maintenance {
    /// One 20 g packet of tablets per kilogram of beans. xBloom's own guidance
    /// is "about every 4 bags of coffee", which is the same thing for a 250 g
    /// bag.
    public static let tabletsGrams: Double = 1_000
    /// xBloom descale every 300 cups or three months, whichever comes first.
    public static let descaleBrews = 300
    public static let descaleMonths = 3
    public static let brushDays = 7

    public static func status(
        _ task: MaintenanceTask,
        usage: MaintenanceUsage,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MaintenanceStatus {
        switch task {
        case .grinderBrush:
            // Only counts weeks the grinder actually ran. A machine that has
            // not ground anything has nothing in its chute to sweep out.
            guard usage.lastGrinderUseAt != nil else {
                return MaintenanceStatus(
                    task: task,
                    isDue: false,
                    progress: 0,
                    summary: "Nothing ground since the last brush",
                    isDormant: true
                )
            }
            let due = calendar.date(byAdding: .day, value: brushDays, to: usage.since) ?? usage.since
            let days = Int(now.timeIntervalSince(usage.since) / 86_400)
            // Past the interval the counter stops being useful — "30 of 7 days"
            // is arithmetic, not an instruction.
            return MaintenanceStatus(
                task: task,
                isDue: now >= due,
                progress: fraction(from: usage.since, to: due, now: now),
                summary: now >= due
                    ? "The grinder has run this week"
                    : days <= 0
                        ? "The grinder ran today"
                        : "\(days) of \(brushDays) days",
                isDormant: false
            )

        case .grinderTablets:
            let grams = max(0, usage.groundGrams)
            return MaintenanceStatus(
                task: task,
                isDue: grams >= tabletsGrams,
                progress: min(1, grams / tabletsGrams),
                summary: grams >= tabletsGrams
                    ? String(format: "%.1f kg ground since the last packet", grams / 1_000)
                    : String(format: "%.0f g of %.0f kg ground", grams, tabletsGrams / 1_000),
                isDormant: grams == 0
            )

        case .descale:
            let due = calendar.date(byAdding: .month, value: descaleMonths, to: usage.since) ?? usage.since
            let byTime = fraction(from: usage.since, to: due, now: now)
            let byBrews = min(1, Double(max(0, usage.brews)) / Double(descaleBrews))
            // Days rather than months: three months in is a bar a third of the
            // way along, and "0 of 3 months" underneath it reads as a
            // contradiction for the first four weeks of every interval.
            let days = calendar.dateComponents([.day], from: usage.since, to: now).day ?? 0
            let span = calendar.dateComponents([.day], from: usage.since, to: due).day ?? 90
            let isDue = usage.brews >= descaleBrews || now >= due
            return MaintenanceStatus(
                task: task,
                isDue: isDue,
                progress: max(byTime, byBrews),
                summary: isDue
                    ? usage.brews >= descaleBrews
                        ? "\(usage.brews) brews since the last descale"
                        : "\(days) days since the last descale"
                    : "\(usage.brews) of \(descaleBrews) brews · \(days) of \(span) days",
                isDormant: usage.brews == 0 && days == 0
            )
        }
    }

    private static func fraction(from start: Date, to end: Date, now: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / span))
    }
}
