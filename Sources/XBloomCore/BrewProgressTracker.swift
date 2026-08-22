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
    /// When the machine accepted the recipe. This is deliberately distinct
    /// from `brewerStartedAt`: an `8002` echo does not mean a mechanism moved.
    public private(set) var recipeAcceptedAt: Date?
    /// When the grinder reported that it had finished. Firmware that omits the
    /// event falls back to the first brewer-side lifecycle frame.
    public private(set) var grinderFinishedAt: Date?
    /// The machine's brewer-start event, kept separate from the `8002` echo.
    /// The echo says the execute command arrived; this says a program began.
    public private(set) var brewerStartedAt: Date?
    /// Whether the machine ever said it was grinding. A recipe that grinds and
    /// reaches its first pour without this is a recipe that poured over dry
    /// beans — the failure this machine gives no error for.
    public private(set) var observedGrinding = false
    /// The pour the machine says it is on, taken from `wateringPhase`.
    public private(set) var pourIndex = 0
    /// True once a `wateringPhase` has arrived, meaning the pour index comes
    /// from the machine rather than from integrating delivered water.
    public private(set) var hasObservedPourEvents = false
    public private(set) var lastPourStartedAt: Date?
    public private(set) var completedAt: Date?
    public private(set) var errorCommand: UInt16?
    public private(set) var lastEventAt: Date?
    /// The first screen the machine reported after accepting the recipe.
    public private(set) var brewingPage: UInt32?
    public private(set) var currentPage: UInt32?
    /// Set once the machine acknowledges the recipe, which is when its screen
    /// becomes meaningful as a progress signal.
    public private(set) var recipeAccepted = false

    /// The machine's home screen. Seen at the end of a brew that was stopped
    /// by hand, and never once during one.
    static let homePage: UInt32 = 1

    public init() {}

    public var isExtracting: Bool { extractionStartedAt != nil }

    public mutating func reset() {
        self = BrewProgressTracker()
    }

    public mutating func ingest(command: UInt16, value: UInt32?, at date: Date = Date()) {
        guard let notification = XBloomNotification(rawValue: command) else { return }
        // Gear movement is streamed like a measurement, but in an automatic
        // recipe it is also the earliest proof that the grinder branch won.
        if notification.isMeasurement, notification != .deviceGears { return }
        lastEventAt = date

        switch notification {
        case .recipeMarking:
            // The recipe has been accepted. Nothing has been poured yet.
            recipeAccepted = true
            if recipeAcceptedAt == nil { recipeAcceptedAt = date }
            if !isExtracting { phase = .preparing }

        case .brewerStart:
            recipeAccepted = true
            if recipeAcceptedAt == nil { recipeAcceptedAt = date }
            if brewerStartedAt == nil { brewerStartedAt = date }
            if !isExtracting { phase = .preparing }

        case .wateringPhase:
            beginPour(index: value.map(Int.init), at: date)

        case .deviceInGrinder:
            if !isExtracting { phase = .preparing }

        case .deviceBeginGrinder, .grinderDoing, .grindBegin, .deviceGears:
            observedGrinding = true
            if !isExtracting { phase = .grinding }

        case .deviceGrinderFinish:
            observedGrinding = true
            if grinderFinishedAt == nil { grinderFinishedAt = date }
            if !isExtracting { phase = .preparing }

        case .deviceBeginBrewer:
            if brewerStartedAt == nil { brewerStartedAt = date }
            if grinderFinishedAt == nil { grinderFinishedAt = date }
            if !isExtracting { phase = .preparing }

        case .deviceOutGrinder, .deviceInBrewer,
             .deviceInScale, .deviceOutScale,
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
        if brewerStartedAt == nil { brewerStartedAt = date }
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
        guard brewingPage != nil else {
            brewingPage = page
            return
        }

        // Only going home ends a recipe.
        //
        // This used to treat *any* change away from the brewing screen as the
        // end, which was wrong the moment the machine was watched properly: it
        // moves between screens constantly while brewing — 30 and 34 while it
        // grinds, 15 on a fault, 2 after a grind, and 31 the instant a brew is
        // paused. A 2026-08-22 12:43 recording ends the session one frame after
        // the pause, because page 35 became page 31 and the app called that a
        // finished cup.
        //
        // This machine sends `take_cup` at a real finish anyway; the page is
        // only a backstop for firmware that does not, so it is worth nothing if
        // it cannot be trusted.
        if page == Self.homePage, isExtracting, completedAt == nil {
            completedAt = date
            phase = .complete
        }
    }
}
