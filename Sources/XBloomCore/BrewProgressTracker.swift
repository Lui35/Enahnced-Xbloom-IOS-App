import Foundation

/// Reads the machine's notification stream as brew lifecycle state.
///
/// Built from a recorded brew rather than from a protocol reference. On this
/// firmware the dripper-position events the reference describes (`9003`,
/// `9005`, `40511`, `40512`) never arrived at all. What the machine actually
/// sends is:
///
/// - `brewerStart` once, when it accepts the recipe;
/// - `wateringPhase` at the start of every pour, carrying that pour's
///   zero-based index in its payload;
/// - `deviceCurrentPage` when its screen changes, which is how a finished
///   recipe announces itself when no completion event is sent;
/// - `brewerVolume` and `weightRealTime` continuously.
///
/// Anything the reference describes but this machine does not send is still
/// handled, so a different firmware degrades rather than breaks.
public struct BrewProgressTracker: Equatable, Sendable {
    public private(set) var phase: BrewProgramPhase = .preparing
    /// When the machine began the first pour. Nil until it does, so the
    /// extraction chart cannot start while the machine is still grinding.
    public private(set) var extractionStartedAt: Date?
    /// When the machine accepted the recipe. For a recipe that does not grind,
    /// this is also when brewing begins.
    public private(set) var recipeAcceptedAt: Date?
    /// When the grinder reported that it had finished. On this firmware the
    /// grinder events have never been seen, so this is usually nil and the
    /// brew clock falls back to the first pour.
    public private(set) var grinderFinishedAt: Date?
    /// The pour the machine says it is on, taken from `wateringPhase`.
    public private(set) var pourIndex = 0
    /// True once a `wateringPhase` has arrived, meaning the pour index comes
    /// from the machine rather than from integrating delivered water.
    public private(set) var hasObservedPourEvents = false
    public private(set) var lastPourStartedAt: Date?
    public private(set) var completedAt: Date?
    public private(set) var errorCommand: UInt16?
    public private(set) var lastEventAt: Date?
    /// The screen the machine was showing while it brewed. A later change away
    /// from it means the recipe is over.
    public private(set) var brewingPage: UInt32?
    public private(set) var currentPage: UInt32?
    /// Set once the machine acknowledges the recipe, which is when its screen
    /// becomes meaningful as a progress signal.
    public private(set) var recipeAccepted = false

    public init() {}

    public var isExtracting: Bool { extractionStartedAt != nil }

    public mutating func reset() {
        self = BrewProgressTracker()
    }

    public mutating func ingest(command: UInt16, value: UInt32?, at date: Date = Date()) {
        guard let notification = XBloomNotification(rawValue: command),
              !notification.isMeasurement else { return }
        lastEventAt = date

        switch notification {
        case .brewerStart, .recipeMarking:
            // The recipe has been accepted. Nothing has been poured yet.
            recipeAccepted = true
            if recipeAcceptedAt == nil { recipeAcceptedAt = date }
            if !isExtracting { phase = .preparing }

        case .wateringPhase:
            beginPour(index: value.map(Int.init), at: date)

        case .deviceInGrinder:
            if !isExtracting { phase = .preparing }

        case .deviceBeginGrinder, .grinderDoing, .grindBegin:
            if !isExtracting { phase = .grinding }

        case .deviceGrinderFinish, .deviceOutGrinder, .deviceInBrewer,
             .deviceInScale, .deviceOutScale, .deviceBeginBrewer,
             .pourFirstVibrationBefore:
            // The grinder is done and the machine is on its way to pouring.
            // It is not heating: this firmware has no heating state and never
            // reports water temperature.
            if grinderFinishedAt == nil { grinderFinishedAt = date }
            if !isExtracting { phase = .preparing }

        case .deviceBrewerPass, .deviceWateringFinish:
            if isExtracting { phase = .resting }

        case .takeCup, .brewerFinish:
            completedAt = date
            phase = .complete

        case .deviceCurrentPage:
            updatePage(value, at: date)

        case .grinderEmptyAbnormal:
            errorCommand = command
            phase = .error

        case .waterTankVolumeLow:
            // A zero payload arrived mid-brew while the machine kept pouring,
            // so only a non-zero level is a real fault.
            if (value ?? 0) != 0 {
                errorCommand = command
                phase = .error
            }

        default:
            break
        }
    }

    private mutating func beginPour(index: Int?, at date: Date) {
        hasObservedPourEvents = true
        // A pour is proof the grinder is done, whether or not it said so.
        if grinderFinishedAt == nil { grinderFinishedAt = date }
        lastPourStartedAt = date
        if extractionStartedAt == nil { extractionStartedAt = date }

        // The machine names the pour it is starting. Clamp forward only, so a
        // repeated or out-of-order frame cannot rewind the display.
        if let index, index >= 0 {
            pourIndex = max(pourIndex, index)
        }
        phase = pourIndex == 0 ? .blooming : .pouring
    }

    private mutating func updatePage(_ page: UInt32?, at date: Date) {
        guard let page else { return }
        currentPage = page
        guard recipeAccepted else { return }

        // The machine reports its screen shortly after accepting the recipe,
        // before the first pour. That screen is the brewing screen.
        guard let brewingPage else {
            brewingPage = page
            return
        }
        // Leaving it is the only completion signal this firmware gives when it
        // sends no finish event at all.
        if page != brewingPage, isExtracting, completedAt == nil {
            completedAt = date
            phase = .complete
        }
    }
}
