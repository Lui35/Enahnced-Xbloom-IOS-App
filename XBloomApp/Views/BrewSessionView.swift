import Charts
import Observation
import SwiftData
import SwiftUI
import XBloomCore

struct BrewSessionView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(XBloomBLEClient.self) var machine
    @Environment(BrewSessionCoordinator.self) var brewSession
    @Query(sort: \StoredBean.updatedAt, order: .reverse) var storedBeans: [StoredBean]

    let recipe: Recipe
    let mode: BrewSessionMode
    let sessionID: UUID
    let resumedAt: Date?
    let restoredWeightBaseline: Double?
    let restoredWaterBaseline: Double?
    let restoredWater: Double?
    let restoredWeight: Double?
    let restoredTemperature: Double?
    let restoredActivePourIndex: Int?
    let restoredPhase: BrewProgramPhase?
    let restoredSamples: [BrewSample]?
    let restoredExtractionStartedAt: Date?
    let restoredExtractionElapsed: TimeInterval?

    @State var startedAt: Date?
    @State var extractionStartedAt: Date?
    @State var brewElapsed: TimeInterval = 0
    @State var elapsed: TimeInterval = 0
    @State var extractionElapsed: TimeInterval = 0
    @State var progress = 0.0
    @State var stage = "Preparing"
    @State var water = 0.0
    @State var weight = 0.0
    @State var temperature: Double?
    @State var activePourIndex = 0
    @State var currentPhase: BrewProgramPhase = .preparing
    @State var samples: [BrewSample] = []
    @State var chartSamples: [BrewSample] = []
    @State var lastChartRenderAt = Date.distantPast
    @State var errorMessage: String?
    @State var hasStarted = false
    @State var savedBrew: StoredBrew?
    @State var recordedCompletion = false
    @State var finished = false
    @State var lastSampleAt: TimeInterval = -.infinity
    @State var weightBaseline: Double?
    /// Whether the preview has already run its grinding segment, so the wait
    /// before the first pour can be named for what follows it.
    @State var hasLeftGrinding = false
    @State var waterBaseline: Double?
    @State var reconnectAttempted = false
    @State var confirmingStop = false
    /// Held mid-recipe. The machine keeps the program loaded, so this is a
    /// hold rather than the stop that ends a session.
    @State var isPaused = false
    /// When the current pause began, and how long every earlier pause lasted.
    /// The machine's program is stopped while it is paused and its own display
    /// stops with it; a plain wall-clock delta does not, so the two readings
    /// drift apart by the length of every pause and never come back.
    @State var pausedAt: Date?
    @State var pausedTotal: TimeInterval = 0
    /// The fault the user has already dismissed. Without it the alert came
    /// back on the next telemetry frame, because the fault itself had not
    /// changed and never will until the next brew.
    @State var acknowledgedFault: UInt16?
    @State var confirmingLeave = false
    @State var waterTracker: BrewDeliveryTracker
    @State var weightTracker: ScaleYieldTracker
    @State var liveTicker: Task<Void, Never>?
    /// When the poured-volume counter last moved. The machine announces the
    /// start of each pour but never its end, so a stalled counter is what marks
    /// the change from pouring to the bed draining.
    @State var lastWaterIncreaseAt: Date?

    init(
        recipe: Recipe,
        mode: BrewSessionMode,
        sessionID: UUID = UUID(),
        resumedAt: Date? = nil,
        restoredWeightBaseline: Double? = nil,
        restoredWaterBaseline: Double? = nil,
        restoredWater: Double? = nil,
        restoredWeight: Double? = nil,
        restoredTemperature: Double? = nil,
        restoredActivePourIndex: Int? = nil,
        restoredPhase: BrewProgramPhase? = nil,
        restoredSamples: [BrewSample]? = nil,
        restoredExtractionStartedAt: Date? = nil,
        restoredExtractionElapsed: TimeInterval? = nil
    ) {
        self.recipe = recipe
        self.mode = mode
        self.sessionID = sessionID
        self.resumedAt = resumedAt
        self.restoredWeightBaseline = restoredWeightBaseline
        self.restoredWaterBaseline = restoredWaterBaseline
        self.restoredWater = restoredWater
        self.restoredWeight = restoredWeight
        self.restoredTemperature = restoredTemperature
        self.restoredActivePourIndex = restoredActivePourIndex
        self.restoredPhase = restoredPhase
        self.restoredSamples = restoredSamples
        self.restoredExtractionStartedAt = restoredExtractionStartedAt
        self.restoredExtractionElapsed = restoredExtractionElapsed
        _chartSamples = State(initialValue: Self.makeChartSamples(restoredSamples ?? []))

        // The machine cannot pour faster than the recipe's quickest pour, so
        // that rate is the ceiling used to reject impossible telemetry jumps.
        let maximumFlowRate = recipe.pours.map(\.flowRate).max() ?? 3
        _waterTracker = State(
            initialValue: BrewDeliveryTracker(
                target: Double(recipe.totalWater),
                maximumRate: maximumFlowRate,
                allowsCounterReset: true
            )
        )
        _weightTracker = State(
            initialValue: ScaleYieldTracker(
                expectedYield: recipe.expectedYield
            )
        )
    }

    var estimatedDuration: TimeInterval {
        let preparation = recipe.useGrinder ? 35.0 : 15.0
        let pourDuration = recipe.pours.reduce(0.0) {
            $0 + Double($1.pauseBefore + $1.pauseAfter) + Double($1.volume) / max(0.1, $1.flowRate)
        }
        return preparation + pourDuration
    }

    var firstPourProgramStart: TimeInterval {
        let preparation = recipe.useGrinder ? 35.0 : 15.0
        return preparation + Double(recipe.pours.first?.pauseBefore ?? 0)
    }

    var estimatedExtractionDuration: TimeInterval {
        Brewing.extractionDuration(recipe: recipe)
    }

    var simulationWallDuration: TimeInterval {
        Brewing.simulationWallDuration(for: estimatedDuration)
    }

    var simulationSpeed: Double {
        guard simulationWallDuration > 0 else { return 1 }
        return estimatedDuration / simulationWallDuration
    }

    /// Markers share the chart's zero: the start of the first pour. Grinding and
    /// heating take an unpredictable amount of time, so anchoring the chart to
    /// the moment the recipe was sent pushed every marker away from the data.
    var chartTimelineEvents: [BrewTimelineEvent] {
        Brewing.extractionEvents(recipe: recipe)
    }

    var chartDuration: TimeInterval {
        max(1, max(estimatedExtractionDuration, chartSamples.last?.elapsed ?? 0))
    }

    var activePour: PourStep? {
        guard recipe.pours.indices.contains(activePourIndex) else { return nil }
        return recipe.pours[activePourIndex]
    }

    /// A grinding recipe that reached its first pour without the machine ever
    /// saying it ground. Nothing else in the system notices this: the recipe is
    /// accepted, water is poured, and every reading looks normal.
    var pouredWithoutGrinding: Bool {
        mode == .live
            && recipe.useGrinder
            && extractionStartedAt != nil
            && !machine.brewProgress.observedGrinding
    }

    /// Whether the scale has actually weighed any coffee this session.
    var hasYieldSignal: Bool {
        mode == .simulation || weightTracker.hasMeasuredYield
    }

    /// Extraction has been running long enough that a working scale would have
    /// something to say by now, and it has said nothing.
    var scaleIsSilent: Bool {
        mode == .live && extractionStartedAt != nil && extractionElapsed > 25 && !hasYieldSignal
    }

    var expectedCupYield: Double { recipe.expectedYield }

    /// The estimate is an estimate. Scaling the curve by it alone pinned a
    /// brew that beat it flat against the top of the chart.
    var yieldScale: Double { max(expectedCupYield, weight) }

    var isSessionLocked: Bool {
        mode == .live
            && hasStarted
            && !finished
            && errorMessage == nil
    }

    private static func makeChartSamples(_ samples: [BrewSample]) -> [BrewSample] {
        let maximumPoints = 120
        guard samples.count > maximumPoints else {
            return BrewGraphSmoother.smooth(samples)
        }
        let step = max(1, Int(ceil(Double(samples.count) / Double(maximumPoints - 1))))
        var reduced = samples.enumerated().compactMap { index, sample in
            index.isMultiple(of: step) ? sample : nil
        }
        if reduced.last != samples.last, let last = samples.last {
            reduced.append(last)
        }
        return BrewGraphSmoother.smooth(reduced)
    }

    func refreshChartIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastChartRenderAt) >= 0.5 else { return }
        lastChartRenderAt = now
        chartSamples = Self.makeChartSamples(samples)
    }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    extractionHero
                    if finished, mode == .live, let savedBrew {
                        QuickBrewFeedback(brew: savedBrew)
                    }
                    sessionTiming
                    if let activePour, [.blooming, .pouring, .resting].contains(currentPhase) {
                        activePourCard(activePour)
                    } else if !finished {
                        preparationCard
                    }
                    if let machineWarning {
                        Label(machineWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(StudioTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
                    }
                    // The pours are what you are following while a brew runs;
                    // the curve is what you read afterwards.
                    pourTimeline
                    extractionChart
                    if mode == .live, !finished, !machine.isConnected {
                        reconnectCard
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(mode == .simulation ? "Brew simulation" : "Live extraction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if mode == .simulation || !isSessionLocked {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { brewSession.dismiss() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { sessionControls }
        .interactiveDismissDisabled(isSessionLocked)
        .confirmationDialog(
            "Stop this brew?",
            isPresented: $confirmingStop,
            titleVisibility: .visible
        ) {
            Button("Confirm", role: .destructive) { stopLiveBrew() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The machine stops pouring straight away. What is already in the cup stays in your history.")
        }
        .confirmationDialog(
            "Close without stopping the machine?",
            isPresented: $confirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Close anyway", role: .destructive) { brewSession.detach() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text(
                "The app cannot reach the xBloom, so it cannot stop it. The machine carries on with the recipe. "
                    + "Reopen the app once it reconnects to pick the session back up, or use Settings › Machine › "
                    + "Stop the machine now."
            )
        }
        .task { await launchSession() }
        .onDisappear {
            liveTicker?.cancel()
            liveTicker = nil
        }
        .onChange(of: machine.telemetry) {
            guard mode == .live else { return }
            captureTelemetry()
        }
        .onChange(of: machine.brewProgress) {
            guard mode == .live, hasStarted, !finished else { return }
            adoptMachineProgress()
            appendLiveSampleIfNeeded()
            finishIfMachineReportsCompletion()
        }
        .onChange(of: machine.connectionState) { _, state in
            guard mode == .live, hasStarted, !finished else { return }
            reconnectAttempted = false
            if state == .connected {
                captureTelemetry()
            } else {
                stage = liveStageTitle
            }
        }
        .alert("Brew error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                acknowledgedFault = machine.brewProgress.errorCommand
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
    }

    /// Always on screen, whatever the session is doing. These used to sit at
    /// the end of the scrolling content, below the chart and every pour card,
    /// while the toolbar's close button was hidden for the duration of a live
    /// brew — so there was no visible way out of a running session.
    /// One control, one shape. The icon carries the meaning: a pause bar
    /// while the brew runs, a play triangle while it holds, a square to stop.
}
