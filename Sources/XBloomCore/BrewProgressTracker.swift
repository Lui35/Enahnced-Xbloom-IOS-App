import Foundation

/// Notification identifiers the xBloom emits while it works through a recipe.
///
/// Names follow the PyBloom reference in `docs/PYBLOOM_BLUETOOTH_API.md`.
public enum XBloomNotification: UInt16, Sendable, CaseIterable {
    case inGrinder = 9000
    case inBrewer = 9001
    case inScale = 9002
    case grinderBegin = 9003
    case outGrinder = 9004
    case brewerBegin = 9005
    case outBrewer = 9006
    case outScale = 9008
    case grinderPause = 9009
    case brewerPause = 9010
    case brewerCoffeeStart = 40502
    case grinderStop = 40507
    case bloom = 40510
    case brewerStop = 40511
    case enjoy = 40512
    case enjoyAlternate = 40513
    case errorIdling = 40517
    case errorLackOfWater = 40522
    case abnormalGearPosition = 8203
    case abnormalDoseOrWater = 8204
    case currentWeight = 20501
    case brewerTemperature = 8108
    case waterVolume = 40523
    case machineInfo = 40521
}

/// Reads the machine's notification stream as brew lifecycle state.
///
/// The xBloom announces what it is doing — dripper position, grinder start and
/// stop, brewer start, bloom, pause, and stop — well before any water reaches
/// the scale. Deriving the phase, the extraction clock, and the pour index from
/// those events keeps the app in step with the machine instead of inferring
/// them from telemetry values that arrive late, arrive rarely, or never arrive.
public struct BrewProgressTracker: Equatable, Sendable {
    public private(set) var phase: BrewProgramPhase = .preparing
    /// The moment the machine began the first pour. Nil until it does, so the
    /// extraction clock and chart cannot start during grinding or heating.
    public private(set) var extractionStartedAt: Date?
    public private(set) var pourIndex = 0
    /// True once the machine has reported at least one pour boundary, which is
    /// when event-driven pour tracking becomes more trustworthy than
    /// integrating the water counter.
    public private(set) var hasObservedPourEvents = false
    /// Set when the brewer reports that it stopped after extraction began. The
    /// recipe is not finished until the machine also says so or stays quiet.
    public private(set) var brewerStoppedAt: Date?
    public private(set) var completedAt: Date?
    public private(set) var errorCommand: UInt16?
    public private(set) var lastEventAt: Date?

    /// A pause was reported and the next brewer start belongs to the next pour.
    private var awaitingNextPour = false

    public init() {}

    public var isExtracting: Bool { extractionStartedAt != nil }

    public mutating func reset() {
        self = BrewProgressTracker()
    }

    public mutating func ingest(command: UInt16, at date: Date = Date()) {
        guard let notification = XBloomNotification(rawValue: command) else { return }
        switch notification {
        case .currentWeight, .brewerTemperature, .waterVolume, .machineInfo:
            // Measurements, not lifecycle. Recording them here would make the
            // tracker change on every reading and mask when the machine last
            // actually did something.
            return
        default:
            lastEventAt = date
        }

        switch notification {
        case .inGrinder:
            if !isExtracting { phase = .preparing }
        case .grinderBegin:
            if !isExtracting { phase = .grinding }
        case .grinderStop, .outGrinder, .inBrewer, .inScale, .outScale:
            // The dripper is on its way to the brewer while the machine brings
            // the water up to temperature. Nothing has been poured yet.
            if !isExtracting { phase = .heating }
        case .brewerBegin, .brewerCoffeeStart, .bloom:
            beginPour(at: date)
        case .brewerPause:
            if isExtracting {
                phase = .resting
                awaitingNextPour = true
            }
        case .brewerStop:
            if isExtracting {
                // Treated as a rest, not as completion: the caller decides that
                // the recipe is over once every pour has been delivered or the
                // machine confirms it.
                brewerStoppedAt = date
                phase = .resting
                awaitingNextPour = true
            } else {
                phase = .preparing
            }
        case .enjoy, .enjoyAlternate:
            completedAt = date
            phase = .complete
        case .errorIdling, .errorLackOfWater, .abnormalGearPosition, .abnormalDoseOrWater:
            errorCommand = command
            phase = .error
        case .outBrewer, .grinderPause, .currentWeight, .brewerTemperature, .waterVolume, .machineInfo:
            break
        }
    }

    /// Confirms completion without waiting for an `enjoy` notification, which
    /// the machine does not always send. The caller supplies the settle window
    /// and whether the recipe's final pour has actually been delivered, so a
    /// brewer stop between pours can never end the session early.
    public mutating func confirmCompletionIfSettled(
        at date: Date,
        finalPourDelivered: Bool,
        settleInterval: TimeInterval = 8
    ) {
        guard completedAt == nil,
              finalPourDelivered,
              let brewerStoppedAt,
              date.timeIntervalSince(brewerStoppedAt) >= settleInterval else { return }
        completedAt = date
        phase = .complete
    }

    private mutating func beginPour(at date: Date) {
        hasObservedPourEvents = true
        brewerStoppedAt = nil

        guard isExtracting else {
            extractionStartedAt = date
            pourIndex = 0
            awaitingNextPour = false
            phase = .blooming
            return
        }

        if awaitingNextPour {
            pourIndex += 1
            awaitingNextPour = false
        }
        phase = pourIndex == 0 ? .blooming : .pouring
    }
}
