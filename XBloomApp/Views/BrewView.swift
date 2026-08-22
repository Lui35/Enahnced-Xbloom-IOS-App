import Charts
import Observation
import SwiftData
import SwiftUI
import XBloomCore

// UserDefaults is documented as thread-safe, but does not currently conform
// to Sendable. This narrow wrapper lets the persistence actor own all async
// writes while the main actor retains synchronous restoration reads.
private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

enum BrewSessionMode: String, Codable, Identifiable {
    case live
    case simulation

    var id: String { rawValue }
}

@MainActor
@Observable
final class BrewSessionCoordinator {
    struct Presentation: Codable, Identifiable, Equatable, Sendable {
        var id: UUID
        var recipe: Recipe
        var mode: BrewSessionMode
        var startedAt: Date?
        var weightBaseline: Double?
        var waterBaseline: Double?
        var water: Double?
        var weight: Double?
        var temperature: Double?
        var activePourIndex: Int?
        var currentPhase: BrewProgramPhase?
        var samples: [BrewSample]?
        var extractionStartedAt: Date?
        var extractionElapsed: TimeInterval?

        var isResume: Bool {
            mode == .live && startedAt != nil
        }
    }

    private(set) var presentation: Presentation?

    private let defaults: UserDefaults
    private let persistenceStore: BrewSessionPersistenceStore
    private let persistenceKey = "xbloom.activeLiveBrew"
    private let maximumRestorationAge: TimeInterval = 60 * 45
    @ObservationIgnored private var lastSnapshotWriteAt = Date.distantPast
    @ObservationIgnored private var persistenceRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        persistenceStore = BrewSessionPersistenceStore(
            defaults: SendableUserDefaults(defaults),
            key: "xbloom.activeLiveBrew"
        )
        guard
            let data = defaults.data(forKey: persistenceKey),
            let saved = try? JSONDecoder().decode(Presentation.self, from: data),
            saved.mode == .live,
            let startedAt = saved.startedAt,
            Date().timeIntervalSince(startedAt) < maximumRestorationAge
        else {
            defaults.removeObject(forKey: persistenceKey)
            return
        }
        presentation = saved
    }

    func present(recipe: Recipe, mode: BrewSessionMode) {
        presentation = Presentation(
            id: UUID(),
            recipe: recipe,
            mode: mode,
            startedAt: nil,
            weightBaseline: nil,
            waterBaseline: nil,
            water: nil,
            weight: nil,
            temperature: nil,
            activePourIndex: nil,
            currentPhase: nil,
            samples: nil,
            extractionStartedAt: nil,
            extractionElapsed: nil
        )
    }

    func markStarted(at date: Date, weightBaseline: Double?, waterBaseline: Double?) {
        guard var current = presentation, current.mode == .live else { return }
        current.startedAt = date
        current.weightBaseline = weightBaseline
        current.waterBaseline = waterBaseline
        presentation = current
        persist(current)
    }

    func updateSnapshot(
        waterBaseline: Double?,
        water: Double,
        weight: Double,
        temperature: Double?,
        activePourIndex: Int,
        currentPhase: BrewProgramPhase,
        samples: [BrewSample],
        extractionStartedAt: Date?,
        extractionElapsed: TimeInterval
    ) {
        guard var current = presentation, current.mode == .live, current.startedAt != nil else { return }
        guard Date().timeIntervalSince(lastSnapshotWriteAt) >= 4 else { return }
        lastSnapshotWriteAt = Date()
        current.waterBaseline = waterBaseline
        current.water = water
        current.weight = weight
        current.temperature = temperature
        current.activePourIndex = activePourIndex
        current.currentPhase = currentPhase
        // Restoration only needs a compact recent trace. The completed history
        // keeps the complete bounded sample set separately.
        current.samples = Array(samples.suffix(240))
        current.extractionStartedAt = extractionStartedAt
        current.extractionElapsed = extractionElapsed
        persist(current)
    }

    func markCompleted() {
        persistenceRevision += 1
        defaults.removeObject(forKey: persistenceKey)
        let revision = persistenceRevision
        Task { await persistenceStore.clear(revision: revision) }
    }

    /// Closes the live view while the machine carries on brewing.
    ///
    /// Reachable only when the machine is unreachable, because stopping it is
    /// otherwise the single way out of a running brew. The saved snapshot is
    /// deliberately left in place, so reopening the app finds the session still
    /// running and offers to pick it back up. Ending the session outright is
    /// `dismiss()`.
    func detach() {
        guard let current = presentation, current.mode == .live, current.startedAt != nil else {
            dismiss()
            return
        }
        presentation = nil
    }

    func dismiss() {
        let dismissedMode = presentation?.mode
        presentation = nil
        persistenceRevision += 1
        defaults.removeObject(forKey: persistenceKey)
        let revision = persistenceRevision
        Task { await persistenceStore.clear(revision: revision) }
        if dismissedMode == .simulation {
            Task { await BrewLiveActivityManager.shared.endSimulationActivities() }
        }
    }

    private func persist(_ presentation: Presentation) {
        persistenceRevision += 1
        let revision = persistenceRevision
        Task { await persistenceStore.save(presentation, revision: revision) }
    }
}

private actor BrewSessionPersistenceStore {
    private let defaults: SendableUserDefaults
    private let key: String
    private var latestRevision = 0

    init(defaults: SendableUserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func save(_ presentation: BrewSessionCoordinator.Presentation, revision: Int) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(presentation) else { return }
        defaults.value.set(data, forKey: key)
    }

    func clear(revision: Int) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        defaults.value.removeObject(forKey: key)
    }
}

struct BrewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var storedRecipes: [StoredRecipe]
    @State private var searchText = ""
    @State private var selectedFilter: RecipeLibraryFilter = .all
    @State private var latestBrewDates: [UUID: Date] = [:]

    init() {
        _storedRecipes = Query(
            FetchDescriptor<StoredRecipe>(
                sortBy: [SortDescriptor(\StoredRecipe.updatedAt, order: .reverse)]
            )
        )
    }

    private var filteredRecipes: [StoredRecipe] {
        storedRecipes.filter { stored in
            if selectedFilter != .all,
               let style = stored.indexedBrewStyle,
               (selectedFilter == .hot ? style != .hot : style != .iced) {
                return false
            }
            guard let recipe = stored.recipe, selectedFilter.includes(recipe) else { return false }
            return recipe.matchesLibrarySearch(searchText)
        }
    }

    private var recentRecipes: [StoredRecipe] {
        let dates = latestBrewDates
        return filteredRecipes
            .filter { dates[$0.id] != nil }
            .sorted { (dates[$0.id] ?? .distantPast) > (dates[$1.id] ?? .distantPast) }
    }

    private var remainingRecipes: [StoredRecipe] {
        let recentIDs = Set(recentRecipes.map(\.id))
        return filteredRecipes.filter { !recentIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        header

                        RecipeLibraryFilterPicker(selection: $selectedFilter)

                        if filteredRecipes.isEmpty {
                            ContentUnavailableView(
                                searchText.isEmpty ? "No \(selectedFilter.rawValue.lowercased()) recipes" : "No recipes found",
                                systemImage: searchText.isEmpty ? "cup.and.saucer" : "magnifyingglass",
                                description: Text("Try a different search or recipe type.")
                            )
                            .frame(minHeight: 320)
                        }

                        if !recentRecipes.isEmpty {
                            librarySectionHeader(
                                "Recently brewed",
                                detail: "Your latest cups, newest first",
                                icon: "clock.arrow.circlepath"
                            )
                        }
                        ForEach(recentRecipes) { stored in
                            if let recipe = stored.recipe {
                                brewLibraryCard(
                                    stored: stored,
                                    recipe: recipe,
                                    lastBrewedAt: latestBrewDates[stored.id]
                                )
                            }
                        }

                        if !remainingRecipes.isEmpty {
                            librarySectionHeader(
                                recentRecipes.isEmpty ? "Recipe library" : "More recipes",
                                detail: recentRecipes.isEmpty
                                    ? "Choose a program to review"
                                    : "Everything else in your library",
                                icon: "books.vertical.fill"
                            )
                        }
                        ForEach(remainingRecipes) { stored in
                            if let recipe = stored.recipe {
                                brewLibraryCard(stored: stored, recipe: recipe, lastBrewedAt: nil)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 34)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Brew")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search recipes to brew"
            )
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { MachineToolbar() }
        }
        .preferredColorScheme(.dark)
        .onAppear { refreshLatestBrewDates() }
    }

    private func refreshLatestBrewDates() {
        var descriptor = FetchDescriptor<StoredBrew>(
            sortBy: [SortDescriptor(\StoredBrew.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 250
        guard let history = try? modelContext.fetch(descriptor) else { return }
        latestBrewDates = history.reduce(into: [:]) { dates, brew in
            guard let recipeID = brew.recipeID ?? brew.entry?.recipeID else { return }
            if dates[recipeID] == nil {
                dates[recipeID] = brew.completedAt
            }
        }
    }

    private func librarySectionHeader(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 34, height: 34)
                .background(StudioTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Choose your cup")
                    .font(.title2.weight(.bold))
                Text("Review the complete program before anything is sent to your xBloom.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
            }
            Spacer()
            Image(systemName: "cup.and.saucer.fill")
                .font(.title2)
                .foregroundStyle(.black)
                .frame(width: 54, height: 54)
                .background(StudioTheme.accent, in: Circle())
        }
        .padding(.top, 8)
    }

    private func brewLibraryCard(stored: StoredRecipe, recipe: Recipe, lastBrewedAt: Date?) -> some View {
        StudioCard(accent: tint(for: recipe)) {
            VStack(alignment: .leading, spacing: 16) {
                if let lastBrewedAt {
                    Label {
                        Text("Last brewed \(lastBrewedAt, style: .relative)")
                    } icon: {
                        Image(systemName: "clock.fill")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.accent)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(recipe.name)
                                .font(.title3.weight(.bold))
                            if recipe.generatedByAI {
                                Label("AI", systemImage: "sparkles")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(StudioTheme.accent, in: Capsule())
                            }
                        }
                        Text([recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.muted)
                            .lineLimit(1)
                        Text("\(recipe.brewStyle == .iced ? "Iced" : "Hot") pour-over · \(recipe.servings ?? 1) cup\(recipe.servings == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioTheme.accent)
                    }
                    Spacer()
                    Text("\(recipe.pours.count)")
                        .font(.system(size: 42, weight: .light, design: .rounded))
                        .foregroundStyle(tint(for: recipe))
                        .overlay(alignment: .topTrailing) {
                            Text("POURS")
                                .font(.system(size: 7, weight: .heavy))
                                .offset(y: -3)
                        }
                }

                HStack(spacing: 8) {
                    compactMetric("\(String(format: "%.1f", recipe.dose)) g", "Dose")
                    compactMetric("\(recipe.totalWater) ml", "Water")
                    compactMetric("1:\(String(format: "%.1f", recipe.ratio))", "Ratio")
                }
                if recipe.brewStyle == .iced {
                    Label("\(recipe.iceGrams) g ice", systemImage: "snowflake")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(StudioTheme.iced)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(StudioTheme.iced.opacity(0.10), in: Capsule())
                }

                if recipe.generatedByAI, let description = recipe.aiDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Pour preview")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                    ForEach(Array(recipe.pours.prefix(3).enumerated()), id: \.element.id) { index, pour in
                        HStack(spacing: 10) {
                            PourPatternMark(pattern: pour.pattern, size: 27)
                            Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(pour.volume) ml · \(pour.temperature)°")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(StudioTheme.muted)
                            if pour.agitationBefore || pour.agitationAfter {
                                AgitationTimingMarks(
                                    before: pour.agitationBefore,
                                    after: pour.agitationAfter,
                                    size: 19
                                )
                            }
                        }
                    }
                    if recipe.pours.count > 3 {
                        Text("+ \(recipe.pours.count - 3) more pours in the full review")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                    }
                }

                NavigationLink {
                    RecipeDetailView(stored: stored, recipe: recipe)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start brewing")
                                .font(.headline)
                            Text("Review details first")
                                .font(.caption)
                                .opacity(0.62)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A brew card's accent. It used to run off the number of pours, in two
    /// colours written out at this call site — so a four-pour recipe was teal
    /// and a five-pour one was tan, for no reason a drinker would recognise.
    /// What the card is about is the drink.
    private func tint(for recipe: Recipe) -> Color {
        recipe.brewStyle == .iced ? StudioTheme.iced : StudioTheme.crema
    }

    private func compactMetric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(StudioTheme.muted)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip, style: .continuous))
    }
}

struct BrewSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(BrewSessionCoordinator.self) private var brewSession
    @Query(sort: \StoredBean.updatedAt, order: .reverse) private var storedBeans: [StoredBean]

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

    @State private var startedAt: Date?
    @State private var extractionStartedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var extractionElapsed: TimeInterval = 0
    @State private var progress = 0.0
    @State private var stage = "Preparing"
    @State private var water = 0.0
    @State private var weight = 0.0
    @State private var temperature: Double?
    @State private var activePourIndex = 0
    @State private var currentPhase: BrewProgramPhase = .preparing
    @State private var samples: [BrewSample] = []
    @State private var chartSamples: [BrewSample] = []
    @State private var lastChartRenderAt = Date.distantPast
    @State private var errorMessage: String?
    @State private var hasStarted = false
    @State private var recordedCompletion = false
    @State private var finished = false
    @State private var lastSampleAt: TimeInterval = -.infinity
    @State private var weightBaseline: Double?
    /// Whether the preview has already run its grinding segment, so the wait
    /// before the first pour can be named for what follows it.
    @State private var hasLeftGrinding = false
    @State private var waterBaseline: Double?
    @State private var reconnectAttempted = false
    @State private var confirmingStop = false
    /// Held mid-recipe. The machine keeps the program loaded, so this is a
    /// hold rather than the stop that ends a session.
    @State private var isPaused = false
    /// The fault the user has already dismissed. Without it the alert came
    /// back on the next telemetry frame, because the fault itself had not
    /// changed and never will until the next brew.
    @State private var acknowledgedFault: UInt16?
    @State private var confirmingLeave = false
    @State private var waterTracker: BrewDeliveryTracker
    @State private var weightTracker: ScaleYieldTracker
    @State private var liveTicker: Task<Void, Never>?
    /// When the poured-volume counter last moved. The machine announces the
    /// start of each pour but never its end, so a stalled counter is what marks
    /// the change from pouring to the bed draining.
    @State private var lastWaterIncreaseAt: Date?

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

    private var estimatedDuration: TimeInterval {
        let preparation = recipe.useGrinder ? 35.0 : 15.0
        let pourDuration = recipe.pours.reduce(0.0) {
            $0 + Double($1.pauseBefore + $1.pauseAfter) + Double($1.volume) / max(0.1, $1.flowRate)
        }
        return preparation + pourDuration
    }

    private var firstPourProgramStart: TimeInterval {
        let preparation = recipe.useGrinder ? 35.0 : 15.0
        return preparation + Double(recipe.pours.first?.pauseBefore ?? 0)
    }

    private var estimatedExtractionDuration: TimeInterval {
        Brewing.extractionDuration(recipe: recipe)
    }

    private var simulationWallDuration: TimeInterval {
        Brewing.simulationWallDuration(for: estimatedDuration)
    }

    private var simulationSpeed: Double {
        guard simulationWallDuration > 0 else { return 1 }
        return estimatedDuration / simulationWallDuration
    }

    /// Markers share the chart's zero: the start of the first pour. Grinding and
    /// heating take an unpredictable amount of time, so anchoring the chart to
    /// the moment the recipe was sent pushed every marker away from the data.
    private var chartTimelineEvents: [BrewTimelineEvent] {
        Brewing.extractionEvents(recipe: recipe)
    }

    private var chartDuration: TimeInterval {
        max(1, max(estimatedExtractionDuration, chartSamples.last?.elapsed ?? 0))
    }

    private var activePour: PourStep? {
        guard recipe.pours.indices.contains(activePourIndex) else { return nil }
        return recipe.pours[activePourIndex]
    }

    /// A grinding recipe that reached its first pour without the machine ever
    /// saying it ground. Nothing else in the system notices this: the recipe is
    /// accepted, water is poured, and every reading looks normal.
    private var pouredWithoutGrinding: Bool {
        mode == .live
            && recipe.useGrinder
            && extractionStartedAt != nil
            && !machine.brewProgress.observedGrinding
    }

    /// Whether the scale has actually weighed any coffee this session.
    private var hasYieldSignal: Bool {
        mode == .simulation || weightTracker.hasMeasuredYield
    }

    /// Extraction has been running long enough that a working scale would have
    /// something to say by now, and it has said nothing.
    private var scaleIsSilent: Bool {
        mode == .live && extractionStartedAt != nil && extractionElapsed > 25 && !hasYieldSignal
    }

    private var expectedCupYield: Double { recipe.expectedYield }

    /// The estimate is an estimate. Scaling the curve by it alone pinned a
    /// brew that beat it flat against the top of the chart.
    private var yieldScale: Double { max(expectedCupYield, weight) }

    private var isSessionLocked: Bool {
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

    private func refreshChartIfNeeded(force: Bool = false) {
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
    private func circleControl(
        systemImage: String,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 68, height: 68)
                .background(tint.opacity(0.16), in: Circle())
                .overlay { Circle().stroke(tint.opacity(0.55), lineWidth: 2) }
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var sessionControls: some View {
        VStack(spacing: 10) {
            if finished {
                Button {
                    brewSession.dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(StudioTheme.mint, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if mode == .simulation {
                Button {
                    brewSession.dismiss()
                } label: {
                    Label("Close preview", systemImage: "xmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(StudioTheme.raised, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if machine.isConnected {
                // Stopping the machine is the only way out of a running brew.
                // Walking away used to be offered beside it, which let the app
                // and the machine disagree about whether coffee was being made
                // — the session closed, the xBloom kept pouring, and nothing on
                // screen said so.
                // Two controls, both circles, one at each margin: a running
                // brew has exactly two things you can do to it and neither
                // needs a word to explain the symbol. The space between them
                // is where the brew says something back.
                HStack(spacing: 12) {
                    circleControl(
                        systemImage: isPaused ? "play.fill" : "pause.fill",
                        tint: StudioTheme.accent,
                        label: isPaused ? "Resume brewing" : "Pause brewing"
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            isPaused ? resumeLiveBrew() : pauseLiveBrew()
                        }
                    }

                    Spacer(minLength: 12)

                    circleControl(
                        systemImage: "stop.fill",
                        tint: StudioTheme.danger,
                        label: "Stop brewing"
                    ) {
                        confirmingStop = true
                    }
                }
                .overlay {
                    if isPaused {
                        Text("Holding — the machine is waiting")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                }
            } else {
                // Nothing can be sent while the link is down, so there is no
                // stop to offer. Reconnecting is the way back to one — but a
                // dropped connection must not lock the app into a session it
                // can no longer control, so closing stays available here and
                // only here, and says plainly what it does not do.
                Button {
                    reconnectAttempted = true
                    machine.connect(resumingBrew: true)
                } label: {
                    Label("Reconnect to stop it", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(StudioTheme.warning, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(
                    machine.connectionState == .scanning
                        || machine.connectionState == .connecting
                        || machine.connectionState == .subscribing
                )

                Button {
                    confirmingLeave = true
                } label: {
                    Label("Close without stopping", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .background(.ultraThinMaterial)
    }

    private var extractionHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.raised, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.015, progress))
                    .stroke(finished ? StudioTheme.mint : StudioTheme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.25), value: progress)
                VStack(spacing: 3) {
                    Image(systemName: phaseIcon)
                        .font(.title2.weight(.bold))
                    Text("\(Int(progress * 100))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(finished ? StudioTheme.mint : StudioTheme.accent)
            }
            .frame(width: 132, height: 132)

            Text(stage)
                .font(.title2.weight(.bold))
            Text(
                mode == .simulation
                    ? String(format: "Realistic %.1f× preview · no machine commands", simulationSpeed)
                    : machine.machineName
            )
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var sessionTiming: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                timingCell(
                    title: finished ? "Completed in" : "Elapsed",
                    value: durationText(
                        finished
                            ? brewElapsed
                            : mode == .simulation
                                ? extractionElapsed
                                : brewingStartedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
                    ),
                    icon: "timer"
                )
                timingCell(
                    title: mode == .simulation ? "Preview time" : "Estimated",
                    value: durationText(mode == .simulation ? simulationWallDuration : estimatedExtractionDuration),
                    icon: "hourglass"
                )
            }
        }
    }

    private func timingCell(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(StudioTheme.muted)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
    }

    private var reconnectCard: some View {
        StudioCard(accent: StudioTheme.warning) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Live monitoring disconnected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StudioTheme.warning)
                Text("The xBloom recipe keeps running on the machine. Reconnecting only attaches to telemetry — it will not stop the brew or send the recipe again.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    private var preparationCard: some View {
        StudioCard(accent: phaseTint) {
            HStack(spacing: 15) {
                Image(systemName: phaseIcon)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(phaseTint)
                    .frame(width: 58, height: 58)
                    .background(phaseTint.opacity(0.14), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
                // The hero above already names the phase and draws this icon.
                // Repeating "Grinding beans" here made the viewport say it
                // three times; the card's job is the detail underneath it.
                VStack(alignment: .leading, spacing: 5) {
                    Text(preparationDetail)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ProgressView()
                    .tint(phaseTint)
            }
        }
    }

    private func activePourCard(_ pour: PourStep) -> some View {
        StudioCard(accent: StudioTheme.accent) {
            HStack(spacing: 15) {
                PourPatternMark(pattern: pour.pattern, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(activePourIndex == 0 ? "Bloom" : "Pour \(activePourIndex + 1)")
                        .font(.title3.weight(.bold))
                    Text("\(pour.volume) ml · \(pour.temperature)°C · \(String(format: "%.1f", pour.flowRate)) ml/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioTheme.muted)
                    Text(patternTitle(pour.pattern))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.accent)
                }
                Spacer()
                if pour.agitationBefore || pour.agitationAfter {
                    AgitationTimingMarks(
                        before: pour.agitationBefore,
                        after: pour.agitationAfter,
                        size: 29
                    )
                }
            }
        }
    }

    private var extractionChart: some View {
        StudioCard(accent: StudioTheme.mint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(StudioTheme.mint)
                        .frame(width: 36, height: 36)
                        .background(
                            StudioTheme.mint.opacity(0.13),
                            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Extraction curve")
                            .font(.headline.weight(.bold))
                        Text(
                            extractionStartedAt == nil
                                ? "Begins when the machine starts the first pour"
                                : "From the first pour · \(samples.count) readings saved"
                        )
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
                Chart {
                    ForEach(chartSamples, id: \.elapsed) { sample in
                        LineMark(
                            x: .value("Time", sample.elapsed),
                            y: .value(
                                "Water",
                                recipe.totalWater > 0
                                    ? min(100, sample.water / Double(recipe.totalWater) * 100)
                                    : 0
                            ),
                            series: .value("Metric", "Water")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StudioTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        LineMark(
                            x: .value("Time", sample.elapsed),
                            y: .value(
                                "Coffee collected",
                                yieldScale > 0
                                    ? min(100, sample.coffeeWeight / yieldScale * 100)
                                    : 0
                            ),
                            series: .value("Metric", "Cup yield")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StudioTheme.mint)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 3,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: [7, 5]
                            )
                        )
                    }

                    RuleMark(y: .value("Target", 100))
                        .foregroundStyle(.white.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    ForEach(chartTimelineEvents) { event in
                        RuleMark(x: .value("Recipe event", event.elapsed))
                            .foregroundStyle(
                                event.kind == .pour
                                    ? StudioTheme.accent.opacity(0.52)
                                    : .white.opacity(0.13)
                            )
                            .lineStyle(
                                StrokeStyle(
                                    lineWidth: event.kind == .pour ? 1.4 : 1,
                                    dash: event.kind == .pour ? [] : [2, 4]
                                )
                            )
                            .annotation(position: .top, alignment: .leading) {
                                if event.kind == .pour {
                                    Text(event.title)
                                        .font(.system(size: 8, weight: .bold, design: .rounded))
                                        .foregroundStyle(StudioTheme.accent)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(StudioTheme.panel.opacity(0.92), in: Capsule())
                                }
                            }
                    }
                }
                .frame(height: 210)
                .chartXScale(domain: 0...chartDuration)
                .chartYScale(domain: 0...100)
                .overlay {
                    if chartSamples.isEmpty {
                        Text(
                            mode == .live
                                ? "Waiting for the machine to finish grinding and heating"
                                : "Waiting for the first pour"
                        )
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(StudioTheme.muted)
                        .padding(.horizontal, 24)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                            .foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel {
                            if let percent = value.as(Int.self) {
                                Text("\(percent)%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(StudioTheme.muted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(.white.opacity(0.05))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(durationText(seconds))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(StudioTheme.muted)
                            }
                        }
                    }
                }
                .chartPlotStyle { plot in
                    plot
                        .background(.black.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
                }

                HStack(spacing: 10) {
                    chartLegend(
                        "Water",
                        value: "\(Int(water.rounded())) / \(recipe.totalWater) ml",
                        color: StudioTheme.accent
                    )
                    chartLegend(
                        "Cup yield",
                        value: hasYieldSignal
                            ? "\(Int(weight.rounded())) / \(Int(expectedCupYield.rounded())) g"
                            : "no reading",
                        color: hasYieldSignal ? StudioTheme.mint : StudioTheme.muted
                    )
                }

                if pouredWithoutGrinding {
                    Label(
                        "This recipe grinds, but the machine never reported grinding — "
                            + "it went straight to pouring. Check the grinder before "
                            + "you drink this one.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if scaleIsSilent {
                    // Better to say the scale is not reporting than to draw a
                    // flat line at zero and call it a measurement.
                    Label(
                        "The machine's scale is not reporting the cup. Check that the "
                            + "cup is on the scale plate and that nothing is leaning on it.",
                        systemImage: "scalemass"
                    )
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Label("Pour start", systemImage: "line.diagonal")
                        .foregroundStyle(StudioTheme.accent)
                    Label("Rest", systemImage: "ellipsis")
                        .foregroundStyle(StudioTheme.muted)
                    Spacer()
                    Text("Target 100%")
                        .foregroundStyle(StudioTheme.muted)
                }
                .font(.caption2.weight(.semibold))

            }
        }
    }

    private func chartLegend(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.muted)
                Text(value)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip, style: .continuous))
    }

    private enum LivePourState {
        case done
        case active
        case upcoming
    }

    private func stateIcon(for state: LivePourState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .active: "drop.circle.fill"
        case .upcoming: "circle"
        }
    }

    /// True once the machine is actually working through the pours. While it is
    /// still grinding or heating, no pour is under way — marking the first one
    /// active there put "Grinding beans · 0 / 50 ml" inside the bloom card.
    private var hasStartedPouring: Bool {
        [.blooming, .pouring, .resting].contains(currentPhase)
    }

    private func state(ofPour index: Int) -> LivePourState {
        if finished || index < activePourIndex { return .done }
        guard hasStartedPouring else { return .upcoming }
        return index == activePourIndex ? .active : .upcoming
    }

    /// Water already delivered into this particular pour, from the running
    /// total. Pours before it have to be complete for it to be under way.
    private func delivered(inPour index: Int) -> Double {
        let before = recipe.pours.prefix(index).reduce(0.0) { $0 + Double($1.volume) }
        let capacity = Double(recipe.pours[index].volume)
        return min(capacity, max(0, water - before))
    }

    private var pourTimeline: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "Pours",
                    detail: hasStartedPouring
                        ? "\(min(activePourIndex + 1, recipe.pours.count)) of \(recipe.pours.count)"
                        : "\(recipe.pours.count) steps",
                    icon: "list.number"
                )
                ForEach(Array(recipe.pours.enumerated()), id: \.element.id) { index, pour in
                    livePourCard(index: index, pour: pour)
                }
            }
        }
    }

    private func livePourCard(index: Int, pour: PourStep) -> some View {
        let state = state(ofPour: index)
        let delivered = delivered(inPour: index)
        let capacity = Double(max(1, pour.volume))
        let share = recipe.totalWater > 0
            ? Int((Double(pour.volume) / Double(recipe.totalWater) * 100).rounded())
            : 0
        let tint: Color = switch state {
        case .done: StudioTheme.mint
        case .active: StudioTheme.accent
        case .upcoming: StudioTheme.muted.opacity(0.9)
        }

        return VStack(spacing: 12) {
            HStack(spacing: 13) {
                // The share of total water used to be set at 34pt in a fixed
                // 66pt column — the biggest number on the brew screen, for the
                // fact that matters least, squeezing the pattern and flow rate
                // into "Spiral p…". It is a caption now, and it says what it is.
                PourPatternMark(pattern: pour.pattern, color: tint, size: 30)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                            .font(.subheadline.weight(.bold))
                        Text("\(pour.volume) ml · \(pour.temperature)°C")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    HStack(spacing: 8) {
                        Text(patternTitle(pour.pattern))
                        Text("·")
                        Text("\(String(format: "%.1f", pour.flowRate)) ml/s")
                        if pour.pauseAfter > 0 {
                            Text("·")
                            Text("\(pour.pauseAfter)s rest")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(index == 0 ? "Bloom" : "Pour \(index + 1)"), \(pour.volume) millilitres at "
                        + "\(pour.temperature) degrees, \(share) percent of the water, "
                        + "\(patternTitle(pour.pattern))"
                )

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    Image(systemName: stateIcon(for: state))
                        .font(.title3)
                        .foregroundStyle(tint)
                    if pour.agitationBefore || pour.agitationAfter {
                        AgitationTimingMarks(
                            before: pour.agitationBefore,
                            after: pour.agitationAfter,
                            size: 17
                        )
                    }
                }
            }

            // Only the running pour gets a live bar; the others would just be
            // a full or empty rectangle saying nothing.
            if state == .active, mode == .live || !finished {
                VStack(spacing: 5) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(StudioTheme.raised)
                            Capsule()
                                .fill(tint)
                                .frame(width: proxy.size.width * min(1, delivered / capacity))
                                .animation(.smooth(duration: 0.25), value: delivered)
                        }
                    }
                    .frame(height: 8)
                    HStack {
                        Text(stageTitle(for: currentPhase))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(tint)
                        Spacer()
                        Text("\(Int(delivered.rounded())) / \(pour.volume) ml")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
            }
        }
        .padding(14)
        .background(
            state == .active ? StudioTheme.raised : StudioTheme.panel,
            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                .stroke(
                    state == .active ? tint : .white.opacity(0.08),
                    lineWidth: state == .active ? 2 : 1
                )
        }
        .opacity(state == .upcoming ? 0.62 : 1)
        .animation(.snappy(duration: 0.22), value: state)
    }

    @MainActor
    private func launchSession() async {
        guard !hasStarted else { return }
        hasStarted = true

        if mode == .live, let resumedAt {
            startedAt = resumedAt
            elapsed = max(0, Date().timeIntervalSince(resumedAt))
            weightBaseline = restoredWeightBaseline
            waterBaseline = restoredWaterBaseline
            water = restoredWater ?? 0
            weight = restoredWeight ?? 0
            waterTracker.restore(delivered: water, baseline: restoredWaterBaseline)
            weightTracker.restore(yield: weight, baseline: restoredWeightBaseline)
            temperature = restoredTemperature
            activePourIndex = restoredActivePourIndex ?? 0
            currentPhase = restoredPhase ?? .preparing
            samples = restoredSamples ?? []
            lastSampleAt = samples.last?.elapsed ?? -.infinity
            refreshChartIfNeeded(force: true)
            extractionStartedAt = restoredExtractionStartedAt
            extractionElapsed = restoredExtractionElapsed ?? 0
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            stage = machine.isConnected ? "Restoring live extraction" : "Reconnecting to active brew"
            await BrewLiveActivityManager.shared.resumeExisting()
            startLiveTicker()
            if machine.isConnected {
                captureTelemetry()
            } else {
                reconnectAttempted = true
                machine.connect(resumingBrew: true)
            }
            return
        }

        let sessionStartedAt = Date()
        startedAt = sessionStartedAt
        if mode == .live {
            weightBaseline = machine.telemetry.weight
            waterBaseline = machine.telemetry.waterVolume
            waterTracker.seedBaseline(waterBaseline, at: sessionStartedAt)
            weightTracker.seedBaseline(weightBaseline)
            brewSession.markStarted(
                at: sessionStartedAt,
                weightBaseline: weightBaseline,
                waterBaseline: waterBaseline
            )
            startLiveTicker()
        }
        await BrewLiveActivityManager.shared.start(
            recipe: recipe,
            machineName: mode == .simulation ? "Brew preview" : machine.machineName,
            initialState: activityState(phase: recipe.useGrinder ? .grinding : .preparing)
        )
        if mode == .simulation {
            await runSimulation()
        } else {
            await runLiveBrew()
        }
    }

    @MainActor
    private func runLiveBrew() async {
        guard machine.isConnected else {
            errorMessage = "The xBloom disconnected before the recipe could start."
            stage = "Connection lost"
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .error), success: false)
            return
        }
        stage = recipe.useGrinder ? "Sending grinder program" : "Sending brew program"
        do {
            try await machine.startBrew(recipe)
            adoptMachineProgress()
        } catch XBloomBLEClient.MachineError.noMachineResponse {
            // The execute command may have succeeded even when the expected
            // acknowledgement was missed. Keep observing instead of abandoning
            // a machine that is visibly brewing.
            stage = "Recipe sent · waiting for live telemetry"
        } catch {
            errorMessage = error.localizedDescription
            stage = "Could not start"
            brewSession.markCompleted()
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .error), success: false)
        }
    }

    @MainActor
    private func runSimulation() async {
        let previewDuration = simulationWallDuration
        let speed = simulationSpeed
        let previewStartedAt = Date()

        while true {
            guard !Task.isCancelled else { return }
            let previewElapsed = Date().timeIntervalSince(previewStartedAt)
            elapsed = min(estimatedDuration, previewElapsed * speed)
            let estimate = Brewing.estimateProgram(
                recipe: recipe,
                elapsed: elapsed,
                grindingDuration: recipe.useGrinder ? 22 : 0,
                settlingDuration: recipe.useGrinder ? 13 : 15
            )
            water = estimate.water
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            weight = expectedCupYield * pow(progress, 1.12)
            temperature = activePour?.temperature.doubleValue
            activePourIndex = estimate.stepIndex
            if estimate.phase == .grinding { hasLeftGrinding = false }
            else if currentPhase == .grinding || estimate.phase != .preparing {
                hasLeftGrinding = true
            }
            currentPhase = estimate.phase
            stage = stageTitle(for: estimate.phase)
            extractionElapsed = max(0, elapsed - firstPourProgramStart)
            // The preview charts the same window a live brew does: nothing is
            // plotted until the first pour begins.
            if extractionElapsed > 0 {
                if extractionStartedAt == nil { extractionStartedAt = Date() }
                samples.append(
                    BrewSample(
                        elapsed: extractionElapsed,
                        water: water,
                        coffeeWeight: weight,
                        temperature: temperature
                    )
                )
                refreshChartIfNeeded()
            }
            await BrewLiveActivityManager.shared.update(
                activityState(phase: estimate.phase),
                force: estimate.phase == .complete
            )
            if previewElapsed >= previewDuration || estimate.complete {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        elapsed = estimatedDuration
        extractionElapsed = estimatedExtractionDuration
        brewElapsed = estimatedExtractionDuration
        water = Double(recipe.totalWater)
        weight = expectedCupYield
        progress = 1
        finished = true
        currentPhase = .complete
        stage = "Brew complete"
        await BrewLiveActivityManager.shared.end(with: activityState(phase: .complete), success: true)
        recordCompletedSession(
            telemetry: XBloomTelemetry(
                state: .complete,
                weight: weight,
                temperature: temperature,
                waterVolume: water
            ),
            durationOverride: extractionElapsed,
            wasSimulated: true
        )
    }

    /// Drives the live session on its own clock so the display keeps moving
    /// through a long bloom rest, when the machine sends nothing at all.
    @MainActor
    private func startLiveTicker() {
        liveTicker?.cancel()
        liveTicker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, mode == .live, !finished else { return }
                tickLiveSession()
            }
        }
    }

    @MainActor
    private func tickLiveSession() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        adoptMachineProgress()
        appendLiveSampleIfNeeded()
        persistSessionSnapshot()
        Task {
            await BrewLiveActivityManager.shared.update(activityState(phase: currentPhase))
        }
        finishIfMachineReportsCompletion()
    }

    /// The store throttles itself, so calling this from the ticker keeps the
    /// restore point current through quiet stretches when the machine sends
    /// nothing — including the moment extraction actually began.
    private func persistSessionSnapshot() {
        brewSession.updateSnapshot(
            waterBaseline: waterBaseline,
            water: water,
            weight: weight,
            temperature: temperature,
            activePourIndex: activePourIndex,
            currentPhase: currentPhase,
            samples: samples,
            extractionStartedAt: extractionStartedAt,
            extractionElapsed: extractionElapsed
        )
    }

    private func captureTelemetry() {
        guard let startedAt, !finished else { return }
        elapsed = Date().timeIntervalSince(startedAt)

        if machine.telemetry.state == .disconnected {
            stage = liveStageTitle
            if !reconnectAttempted {
                reconnectAttempted = true
                machine.connect(resumingBrew: true)
            }
            return
        }

        let readingTime = Date()
        if let rawWater = machine.telemetry.waterVolume {
            let previous = water
            water = waterTracker.ingest(rawValue: rawWater, at: readingTime)
            if water > previous + 0.05 { lastWaterIncreaseAt = readingTime }
        }
        waterBaseline = waterTracker.currentBaseline
        if let rawWeight = machine.telemetry.weight {
            weight = weightTracker.ingest(rawValue: rawWeight, at: readingTime)
            weightBaseline = weightTracker.currentBaseline
        }
        if let rawTemperature = machine.telemetry.temperature,
           rawTemperature.isFinite,
           (0...110).contains(rawTemperature) {
            temperature = rawTemperature
        }

        adoptMachineProgress()
        appendLiveSampleIfNeeded(force: machine.brewProgress.completedAt != nil)
        persistSessionSnapshot()
        Task {
            await BrewLiveActivityManager.shared.update(
                activityState(phase: currentPhase),
                force: currentPhase == .complete
            )
        }

        if machine.telemetry.state == .error,
           errorMessage == nil,
           acknowledgedFault != machine.brewProgress.errorCommand {
            errorMessage = machineErrorMessage
        }

        // The machine stops itself on an empty grinder — it reports the fault,
        // finishes the grind and returns to its alert screen. The session was
        // left running against a machine that had already given up, offering
        // Pause and Stop for a brew that was over.
        if machine.brewProgress.errorCommand == XBloomNotification.grinderEmptyAbnormal.rawValue,
           !finished {
            abandonLiveSession(reason: "The grinder found no beans, so the machine stopped.")
        }

        finishIfMachineReportsCompletion()
    }

    /// Folds the machine's reported lifecycle into the session's own state.
    /// Everything here only ever moves forward, so a dropped connection or a
    /// missed notification cannot rewind the pour count or the clock.
    @MainActor
    private func adoptMachineProgress() {
        guard mode == .live, !finished else { return }
        let machineProgress = machine.brewProgress

        // Extraction begins when the machine reports its first watering phase.
        // Water starting to move is kept as a fallback for firmware that does
        // not send that event, which otherwise left the session in preparation
        // right through a pour.
        if extractionStartedAt == nil {
            if let machineStart = machineProgress.extractionStartedAt {
                extractionStartedAt = machineStart
            } else if water > 0.5 {
                extractionStartedAt = Date()
            }
            if extractionStartedAt != nil {
                lastSampleAt = -.infinity
                // Zero the scale on the cup as it stands now. The session
                // baseline was taken before grinding, when the cup was not
                // necessarily on the machine yet — so anything put in place
                // during preparation counted as coffee.
                weightTracker.rebaselineAtExtractionStart()
                weight = weightTracker.yield
                weightBaseline = weightTracker.currentBaseline
            }
        }

        if let extractionStartedAt {
            extractionElapsed = max(0, Date().timeIntervalSince(extractionStartedAt))
            // The machine names the pour it is on in every watering-phase
            // frame. Delivered water is only a fallback for firmware that
            // does not send them.
            let reportedIndex = machineProgress.hasObservedPourEvents
                ? machineProgress.pourIndex
                : pourIndexFromDeliveredWater
            let resolvedIndex = min(
                max(0, recipe.pours.count - 1),
                max(activePourIndex, reportedIndex)
            )
            if resolvedIndex != activePourIndex {
                // A new pour is starting; give the counter a moment to move
                // before the display calls it a rest.
                lastWaterIncreaseAt = Date()
                activePourIndex = resolvedIndex
            }
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
        } else {
            // Grinding is preparation, not pour time.
            extractionElapsed = 0
            activePourIndex = 0
            progress = 0
        }

        currentPhase = resolvedLivePhase
        // Keep the "sending the program" message until the machine answers,
        // rather than replacing it with a phase nothing has confirmed yet.
        if machine.brewProgress.lastEventAt != nil || !machine.isSendingRecipe {
            stage = liveStageTitle
        }
    }

    /// True once the machine is on the recipe's last pour and has delivered
    /// essentially all of its water.
    private var finalPourDelivered: Bool {
        guard !recipe.pours.isEmpty else { return true }
        guard activePourIndex >= recipe.pours.count - 1 else { return false }
        let target = Double(recipe.totalWater)
        return target <= 0 || water >= target * 0.95
    }

    /// A backstop for firmware that neither reports a finish event nor changes
    /// its screen. Only fires after the last pour is fully delivered and the
    /// counter has been still far longer than any rest in the recipe.
    private var hasDrainedAfterFinalPour: Bool {
        guard finalPourDelivered, let lastWaterIncreaseAt else { return false }
        let longestRest = recipe.pours.map { Double($0.pauseAfter) }.max() ?? 0
        return Date().timeIntervalSince(lastWaterIncreaseAt) > max(45, longestRest + 20)
    }

    @MainActor
    private func finishIfMachineReportsCompletion() {
        guard !finished, !recordedCompletion else { return }
        // A completion signal before any pour has happened belongs to the
        // machine's previous cycle, not to this brew. Honouring it ended the
        // session seconds after it started, with every pour marked done.
        guard extractionStartedAt != nil else { return }
        guard machine.brewProgress.completedAt != nil
                || machine.telemetry.state == .complete
                || hasDrainedAfterFinalPour else {
            return
        }
        completeLiveSession()
    }

    /// Ends a session the machine has abandoned. No coffee was made, so
    /// nothing is written to history — unlike `completeLiveSession`, which
    /// records the cup.
    @MainActor
    private func abandonLiveSession(reason: String) {
        liveTicker?.cancel()
        liveTicker = nil
        isPaused = false
        finished = true
        currentPhase = .error
        stage = reason
        brewSession.markCompleted()
        Task {
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .error), success: false)
        }
    }

    @MainActor
    private func pauseLiveBrew() {
        do {
            try machine.pauseBrew()
            withAnimation(.snappy(duration: 0.22)) { isPaused = true }
            stage = "Paused"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func resumeLiveBrew() {
        do {
            try machine.resumeBrew()
            withAnimation(.snappy(duration: 0.22)) { isPaused = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func completeLiveSession() {
        liveTicker?.cancel()
        liveTicker = nil
        let endedAt = machine.brewProgress.completedAt ?? Date()
        if let extractionStartedAt {
            extractionElapsed = max(0, endedAt.timeIntervalSince(extractionStartedAt))
        }
        brewElapsed = brewingStartedAt.map { max(0, endedAt.timeIntervalSince($0)) } ?? extractionElapsed
        finished = true
        progress = 1
        currentPhase = .complete
        stage = "Brew complete"
        appendLiveSampleIfNeeded(force: true)
        brewSession.markCompleted()
        Task {
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .complete), success: true)
        }
        recordCompletedSession(
            telemetry: machine.telemetry,
            durationOverride: brewElapsed
        )
    }

    @MainActor
    private func recordCompletedSession(
        telemetry: XBloomTelemetry,
        durationOverride: TimeInterval? = nil,
        wasSimulated: Bool = false
    ) {
        guard !recordedCompletion, let startedAt else { return }
        recordedCompletion = true
        let bean = storedBeans.first { $0.id == recipe.beanID }
        // History must store the session-relative values shown in the UI, not
        // the machine's raw lifetime counters or the scale's tare baseline.
        let sessionTelemetry = XBloomTelemetry(
            state: telemetry.state,
            weight: weight,
            temperature: temperature,
            waterVolume: water,
            waterLevelOK: telemetry.waterLevelOK,
            lastCommand: telemetry.lastCommand
        )
        do {
            try LocalLibrary.recordCompletedBrew(
                id: sessionID,
                recipe: recipe,
                bean: bean,
                startedAt: startedAt,
                telemetry: sessionTelemetry,
                samples: samples,
                durationOverride: durationOverride,
                wasSimulated: wasSimulated,
                in: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Samples are timestamped from the first pour, never from the moment the
    /// recipe was sent, so the curve and the recipe markers describe the same
    /// clock and nothing is plotted while the machine is still grinding.
    private func appendLiveSampleIfNeeded(force: Bool = false) {
        guard extractionStartedAt != nil else { return }
        guard force || extractionElapsed - lastSampleAt >= 0.25 else { return }
        lastSampleAt = extractionElapsed
        samples.append(
            BrewSample(
                elapsed: extractionElapsed,
                water: water,
                coffeeWeight: weight,
                temperature: temperature
            )
        )
        refreshChartIfNeeded(force: force)

        // Four readings per second retain smooth history while the chart uses
        // a cached two-Hz, 120-point representation.
        if samples.count > 2_400 {
            samples.removeFirst(200)
        }
    }

    private var pourIndexFromDeliveredWater: Int {
        var cumulative = 0.0
        for (index, pour) in recipe.pours.enumerated() {
            cumulative += Double(pour.volume)
            if water <= cumulative { return index }
        }
        return max(0, recipe.pours.count - 1)
    }

    private var resolvedLivePhase: BrewProgramPhase {
        if finished { return .complete }
        if machine.telemetry.state == .error { return .error }
        let machinePhase = machine.brewProgress.phase
        guard extractionStartedAt != nil else { return machinePhase }

        // Extraction has already begun. A reconnect clears the machine-side
        // tracker, so never fall back to a preparation phase the brew has left.
        switch machinePhase {
        case .preparing, .grinding:
            return activePourIndex == 0 ? .blooming : .pouring
        case .blooming, .pouring:
            // The machine says when a pour starts but not when it ends. Once
            // the poured-volume counter stops climbing, the bed is draining.
            return isWaterFlowing ? machinePhase : .resting
        default:
            return machinePhase
        }
    }

    /// Names the fault where the machine names it. An empty grinder is by far
    /// the most likely one on a recipe that grinds, and "check the machine"
    /// does not help you work that out.
    /// Faults the machine names, and which of them should interrupt you.
    ///
    /// A low tank is reported by a machine that carries on brewing regardless,
    /// and the one time it was captured it arrived mid-pour with a zero
    /// payload. It belongs in a banner, not in an alert that stops the session.
    private var machineErrorMessage: String? {
        let command = machine.brewProgress.errorCommand
        switch XBloomNotification(rawValue: command ?? 0) {
        case .grinderEmptyAbnormal:
            return recipe.useGrinder
                ? "The grinder found no beans. Put your dose into the grinder, then start the recipe again."
                : "The grinder reported no beans, but this recipe does not grind. Check the machine before retrying."
        case .waterTankVolumeLow:
            return nil
        default:
            if let existing = machine.lastError { return existing }
            // Naming the identifier makes a one-off fault identifiable next
            // time instead of an unreproducible "machine error".
            let identifier = command.map { " (report \($0))" } ?? ""
            return "The xBloom reported a fault\(identifier). The app kept your extraction record; "
                + "check the machine display before stopping anything. Settings › Machine diagnostics "
                + "records the exact frames if it happens again."
        }
    }

    /// Shown inline while the brew carries on, rather than interrupting it.
    private var machineWarning: String? {
        guard XBloomNotification(rawValue: machine.brewProgress.errorCommand ?? 0) == .waterTankVolumeLow
        else { return nil }
        return "The machine reported the water tank running low."
    }

    private var isWaterFlowing: Bool {
        guard let lastWaterIncreaseAt else { return true }
        return Date().timeIntervalSince(lastWaterIncreaseAt) < 2.5
    }

    private var liveStageTitle: String {
        if finished { return "Brew complete" }
        switch machine.connectionState {
        case .disconnected, .unavailable:
            return "Live brew continues · reconnect to monitor"
        case .scanning, .connecting, .subscribing:
            return "Reconnecting to active brew"
        case .connected:
            return stageTitle(for: currentPhase)
        }
    }

    private func stageTitle(for phase: BrewProgramPhase) -> String {
        switch phase {
        case .preparing: hasGroundBeans ? "Getting ready to pour" : "Preparing brewer"
        case .grinding: "Grinding beans"
        case .blooming: "Blooming"
        case .pouring: "Pour \(activePourIndex + 1)"
        case .resting: activePourIndex == 0 ? "Bloom rest" : "Rest after pour \(activePourIndex + 1)"
        case .complete: "Brew complete"
        case .error: "Machine needs attention"
        }
    }

    private var phaseIcon: String {
        if finished { return "checkmark" }
        return switch currentPhase {
        case .preparing: hasGroundBeans ? "arrow.down.to.line" : "cup.and.saucer.fill"
        case .grinding: "circle.grid.cross.fill"
        case .blooming: "drop.circle.fill"
        case .pouring: "water.waves"
        case .resting: "pause.fill"
        case .complete: "checkmark"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var phaseTint: Color {
        return switch currentPhase {
        case .grinding: StudioTheme.crema
        case .blooming, .pouring: StudioTheme.accent
        case .resting: StudioTheme.muted
        case .complete: StudioTheme.mint
        case .error: StudioTheme.danger
        case .preparing: StudioTheme.muted
        }
    }

    /// True once the beans are ground and the machine is working towards the
    /// first pour.
    private var hasGroundBeans: Bool {
        if mode == .live { return machine.brewProgress.grinderFinishedAt != nil }
        return hasLeftGrinding
    }

    /// Zero on the brew clock.
    ///
    /// The machine's own brew begins when the grinder stops: it agitates and
    /// pours from there, with no heating step in between. The clock used to
    /// wait for the first pour event, so it sat at 0:00 through everything
    /// that had already started happening.
    private var brewingStartedAt: Date? {
        guard mode == .live else { return nil }
        return machine.brewProgress.recipeAcceptedAt ?? extractionStartedAt
    }

    /// What the machine's own display reads. Kept separate from
    /// `extractionElapsed`, which is the chart's zero and has to stay on the
    /// first pour so the recipe markers line up with the data.
    @State private var brewElapsed: TimeInterval = 0

    private var preparationDetail: String {
        return switch currentPhase {
        case .grinding: "Grinding \(Int(recipe.dose.rounded())) g at \(recipe.rpm.rawValue) RPM"
        case .resting: "Letting the coffee bed drain before the next pour"
        case .error: "Check the machine display before restarting"
        default: mode == .live
            ? "Waiting for the machine to start · pours have not begun"
            : "Preparing the simulated machine workflow"
        }
    }

    private func activityState(phase: BrewProgramPhase) -> BrewActivityAttributes.ContentState {
        let currentPour = [.blooming, .pouring, .resting].contains(phase) ? activePourIndex + 1 : 0
        return BrewActivityAttributes.ContentState(
            phase: phase,
            stageTitle: mode == .live && phase == currentPhase ? liveStageTitle : stageTitle(for: phase),
            progress: progress,
            currentPour: currentPour,
            totalPours: recipe.pours.count,
            waterML: water,
            targetWaterML: recipe.totalWater,
            coffeeWeight: weight,
            temperature: temperature,
            elapsedSeconds: Int(extractionElapsed.rounded()),
            remainingSeconds: max(0, Int((estimatedExtractionDuration - extractionElapsed).rounded()))
        )
    }

    private func stopLiveBrew() {
        do {
            try machine.stopBrew()
            liveTicker?.cancel()
            liveTicker = nil
            stage = "Brew stopped"
            finished = true
            // A stopped brew is still a finished session: clear the restore
            // snapshot so the next launch does not resurrect it, and keep the
            // partial extraction in history.
            brewSession.markCompleted()
            Task {
                await BrewLiveActivityManager.shared.end(
                    with: activityState(phase: .error),
                    success: false
                )
            }
            recordCompletedSession(
                telemetry: machine.telemetry,
                durationOverride: extractionElapsed
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func patternTitle(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Center pour"
        case .circular: "Circular pour"
        case .spiral: "Spiral pour"
        }
    }

}

private extension Int {
    var doubleValue: Double { Double(self) }
}
