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
                .background(StudioTheme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
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
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.cyan.opacity(0.10), in: Capsule())
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
                    .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
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
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func tint(for recipe: Recipe) -> Color {
        switch recipe.pours.count {
        case 0...3: Color(red: 0.64, green: 0.73, blue: 0.86)
        case 4: StudioTheme.accent
        default: Color(red: 0.82, green: 0.72, blue: 0.48)
        }
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
    @State private var waterBaseline: Double?
    @State private var lastRawWater: Double?
    @State private var reconnectAttempted = false

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
        max(0, estimatedDuration - firstPourProgramStart)
    }

    private var simulationWallDuration: TimeInterval {
        Brewing.simulationWallDuration(for: estimatedDuration)
    }

    private var simulationSpeed: Double {
        guard simulationWallDuration > 0 else { return 1 }
        return estimatedDuration / simulationWallDuration
    }

    private var chartTimelineEvents: [BrewTimelineEvent] {
        Brewing.timelineEvents(
            recipe: recipe,
            grindingDuration: recipe.useGrinder ? 22 : 0,
            heatingDuration: recipe.useGrinder ? 13 : 15
        )
    }

    private var chartPourEvents: [BrewTimelineEvent] {
        chartTimelineEvents.filter { $0.kind == .pour }
    }

    private var chartDuration: TimeInterval {
        max(1, max(estimatedDuration, chartSamples.last?.elapsed ?? 0))
    }

    private var activePour: PourStep? {
        guard recipe.pours.indices.contains(activePourIndex) else { return nil }
        return recipe.pours[activePourIndex]
    }

    private var expectedCupYield: Double {
        // A practical pour-over estimate: roughly 2 g of water remains in the
        // coffee bed for every gram of dry coffee.
        max(1, Double(recipe.totalWater) - (recipe.dose * 2))
    }

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
                    liveMetrics
                    if let activePour, [.blooming, .pouring, .resting].contains(currentPhase) {
                        activePourCard(activePour)
                    } else if mode == .simulation && !finished {
                        preparationCard
                    }
                    extractionChart
                    pourTimeline
                    if mode == .live && !finished && machine.isConnected {
                        Button(role: .destructive) {
                            stopLiveBrew()
                        } label: {
                            Label("Stop brewing", systemImage: "stop.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                    } else if mode == .live && !finished {
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
        .interactiveDismissDisabled(isSessionLocked)
        .task { await launchSession() }
        .onChange(of: machine.telemetry) {
            guard mode == .live else { return }
            captureTelemetry()
        }
        .onChange(of: machine.connectionState) { _, state in
            guard mode == .live, hasStarted, !finished else { return }
            if state == .connected {
                reconnectAttempted = false
                stage = "Reconnected · waiting for machine"
                captureTelemetry()
            } else if state == .disconnected || state == .unavailable {
                reconnectAttempted = false
                stage = "Live brew continues · reconnect to monitor"
            }
        }
        .alert("Brew error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
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
                    title: "Local time",
                    value: context.date.formatted(date: .omitted, time: .shortened),
                    icon: "clock.fill"
                )
                timingCell(
                    title: finished ? "Completed in" : "Elapsed",
                    value: durationText(
                        finished
                            ? extractionElapsed
                            : mode == .simulation
                                ? extractionElapsed
                                : extractionStartedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
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
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var liveMetrics: some View {
        VStack(spacing: 12) {
            extractionProgressMetric(
                title: "Water poured",
                detail: mode == .live ? "Machine delivery" : "Simulated delivery",
                value: water,
                target: Double(recipe.totalWater),
                unit: "ml",
                icon: "drop.fill",
                tint: StudioTheme.accent
            )
            extractionProgressMetric(
                title: "Coffee collected",
                detail: mode == .live ? "Live xBloom scale" : "Simulated cup yield",
                value: weight,
                target: expectedCupYield,
                unit: "g",
                icon: "scalemass.fill",
                tint: StudioTheme.mint,
                targetIsEstimate: true
            )
            extractionMetric("Water temperature", temperature.map { "\(String(format: "%.1f", $0))°C" } ?? "Heating…", "thermometer.medium", .orange)
        }
    }

    private var reconnectCard: some View {
        StudioCard(accent: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Live monitoring disconnected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.orange)
                Text("The xBloom recipe keeps running on the machine. Reconnect only attaches to telemetry—it will not stop the brew or send the recipe again.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                Button {
                    reconnectAttempted = true
                    stage = "Reconnecting to active brew"
                    machine.connect(resumingBrew: true)
                } label: {
                    Label("Reconnect live monitoring", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.orange, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(
                    machine.connectionState == .scanning
                        || machine.connectionState == .connecting
                        || machine.connectionState == .subscribing
                )
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
                    .background(phaseTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(stage)
                        .font(.title3.weight(.bold))
                    Text(preparationDetail)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                ProgressView()
                    .tint(phaseTint)
            }
        }
    }

    private func extractionProgressMetric(
        title: String,
        detail: String,
        value: Double,
        target: Double,
        unit: String,
        icon: String,
        tint: Color,
        targetIsEstimate: Bool = false
    ) -> some View {
        let fraction = target > 0 ? min(1, max(0, value / target)) : 0

        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                HStack(spacing: 11) {
                    Image(systemName: icon)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline.weight(.bold))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(String(format: "%.1f", value)) \(unit)")
                        .font(.title3.weight(.bold).monospacedDigit())
                    Text("\(targetIsEstimate ? "est. " : "")target \(Int(target.rounded())) \(unit)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudioTheme.muted)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(StudioTheme.raised)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.72), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 13)
            .animation(.smooth(duration: 0.25), value: fraction)

            HStack {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                Spacer()
                if targetIsEstimate {
                    Text("Measured weight stays exact")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.muted)
                }
            }
        }
        .padding(16)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(0.55), lineWidth: 1.5)
        }
    }

    private func extractionMetric(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
            Spacer()
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .padding(16)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.58), lineWidth: 1.5)
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
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Extraction curve")
                            .font(.headline.weight(.bold))
                        Text("Normalized progress · \(samples.count) readings saved")
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
                                expectedCupYield > 0
                                    ? min(100, sample.coffeeWeight / expectedCupYield * 100)
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
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack(spacing: 10) {
                    chartLegend(
                        "Water",
                        value: "\(Int(water.rounded())) / \(recipe.totalWater) ml",
                        color: StudioTheme.accent
                    )
                    chartLegend(
                        "Cup yield",
                        value: "\(Int(weight.rounded())) / \(Int(expectedCupYield.rounded())) g",
                        color: StudioTheme.mint
                    )
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

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 7), count: 3),
                    spacing: 7
                ) {
                    ForEach(chartPourEvents) { event in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(StudioTheme.accent)
                                .frame(width: 6, height: 6)
                            Text(event.title)
                                .fontWeight(.bold)
                                .layoutPriority(1)
                            Text(durationText(event.elapsed))
                                .foregroundStyle(StudioTheme.muted)
                        }
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(StudioTheme.raised, in: Capsule())
                    }
                }
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
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var pourTimeline: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionTitle(title: "Recipe timeline", detail: "\(recipe.pours.count) pours", icon: "list.number")
                ForEach(Array(recipe.pours.enumerated()), id: \.element.id) { index, pour in
                    HStack(spacing: 12) {
                        PourPatternMark(
                            pattern: pour.pattern,
                            color: index <= activePourIndex ? StudioTheme.accent : StudioTheme.muted,
                            size: 31
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                            Text("\(pour.volume) ml · \(pour.pauseAfter)s rest · \(patternTitle(pour.pattern))")
                                .font(.caption)
                                .foregroundStyle(StudioTheme.muted)
                        }
                        Spacer()
                        if pour.agitationBefore || pour.agitationAfter {
                            AgitationTimingMarks(
                                before: pour.agitationBefore,
                                after: pour.agitationAfter,
                                size: 20
                            )
                        }
                        Image(systemName: index < activePourIndex || finished ? "checkmark.circle.fill" : (index == activePourIndex ? "circle.inset.filled" : "circle"))
                            .foregroundStyle(index <= activePourIndex || finished ? StudioTheme.mint : StudioTheme.muted)
                    }
                }
            }
        }
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
            lastRawWater = machine.telemetry.waterVolume
            water = restoredWater ?? 0
            weight = restoredWeight ?? 0
            temperature = restoredTemperature
            activePourIndex = restoredActivePourIndex ?? 0
            currentPhase = restoredPhase ?? .preparing
            samples = restoredSamples ?? []
            refreshChartIfNeeded(force: true)
            extractionStartedAt = restoredExtractionStartedAt
            extractionElapsed = restoredExtractionElapsed ?? 0
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            stage = machine.isConnected ? "Restoring live extraction" : "Reconnecting to active brew"
            await BrewLiveActivityManager.shared.resumeExisting()
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
            lastRawWater = waterBaseline
            brewSession.markStarted(
                at: sessionStartedAt,
                weightBaseline: weightBaseline,
                waterBaseline: waterBaseline
            )
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
            stage = machine.telemetry.state.rawValue.capitalized
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
                heatingDuration: recipe.useGrinder ? 13 : 15
            )
            water = estimate.water
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            weight = expectedCupYield * pow(progress, 1.12)
            temperature = estimate.phase == .heating
                ? 72 + min(1, elapsed / 15) * 20
                : activePour?.temperature.doubleValue
            activePourIndex = estimate.stepIndex
            currentPhase = estimate.phase
            stage = stageTitle(for: estimate.phase)
            extractionElapsed = max(0, elapsed - firstPourProgramStart)
            if extractionElapsed > 0, extractionStartedAt == nil {
                extractionStartedAt = Date()
            }
            samples.append(BrewSample(elapsed: elapsed, water: water, coffeeWeight: weight, temperature: temperature))
            refreshChartIfNeeded()
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

    private func captureTelemetry() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)

        if machine.telemetry.state == .disconnected, !finished {
            stage = "Reconnecting to active brew"
            if !reconnectAttempted {
                reconnectAttempted = true
                machine.connect(resumingBrew: true)
            }
            return
        }

        if let rawWater = machine.telemetry.waterVolume {
            water = sanitizedWater(rawWater)
        }
        if let rawWeight = machine.telemetry.weight {
            weight = sanitizedCollectedWeight(rawWeight)
        }
        if let rawTemperature = machine.telemetry.temperature,
           rawTemperature.isFinite,
           (0...110).contains(rawTemperature) {
            temperature = rawTemperature
        }
        var machinePhase = liveActivityPhase
        currentPhase = machinePhase
        if machinePhase == .blooming || machinePhase == .pouring || machinePhase == .resting {
            if extractionStartedAt == nil, water > 0.5 {
                extractionStartedAt = Date()
            }
            if let extractionStartedAt {
                extractionElapsed = max(0, Date().timeIntervalSince(extractionStartedAt))
            }
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            updateActivePour(for: water)
            machinePhase = liveActivityPhase
            currentPhase = machinePhase
        } else if machinePhase != .complete {
            // Grinder and heater telemetry is preparation, not pour time.
            progress = 0
            activePourIndex = 0
        }
        stage = liveStageTitle
        appendLiveSampleIfNeeded(force: machine.telemetry.state == .complete)
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
        Task {
            await BrewLiveActivityManager.shared.update(
                activityState(phase: machinePhase),
                force: machine.telemetry.state == .complete
            )
        }

        if machine.telemetry.state == .error, !finished, errorMessage == nil {
            errorMessage = machine.lastError
                ?? "The xBloom reported a machine error. The app kept your extraction record; check the machine display before stopping anything."
        }

        guard machine.telemetry.state == .complete, !recordedCompletion else { return }
        if let extractionStartedAt {
            extractionElapsed = max(0, Date().timeIntervalSince(extractionStartedAt))
        }
        finished = true
        progress = 1
        stage = "Brew complete"
        brewSession.markCompleted()
        Task {
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .complete), success: true)
        }
        recordCompletedSession(
            telemetry: machine.telemetry,
            durationOverride: extractionElapsed
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

    private func appendLiveSampleIfNeeded(force: Bool = false) {
        guard force || elapsed - lastSampleAt >= 0.25 else { return }
        lastSampleAt = elapsed
        samples.append(BrewSample(elapsed: elapsed, water: water, coffeeWeight: weight, temperature: temperature))
        refreshChartIfNeeded(force: force)

        // Four readings per second retain smooth history while the chart uses
        // a cached two-Hz, 120-point representation.
        if samples.count > 2_400 {
            samples.removeFirst(200)
        }
    }

    private func sanitizedWater(_ candidate: Double) -> Double {
        guard candidate.isFinite, candidate >= 0 else { return water }
        let target = Double(recipe.totalWater)
        if waterBaseline == nil {
            waterBaseline = candidate
            lastRawWater = candidate
            return water
        }

        // A newly executed program may initially report the previous brew's
        // cumulative counter before resetting to zero. Rebase that reset so a
        // stale value cannot jump the UI straight to the final pour.
        if let lastRawWater, candidate + 5 < lastRawWater {
            waterBaseline = 0
        }
        lastRawWater = candidate

        let delivered = max(0, candidate - (waterBaseline ?? candidate))
        let maximum = max(target + 8, target * 1.05)
        guard delivered <= maximum else { return water }
        guard delivered + 2 >= water else { return water }
        return min(maximum, max(water, delivered))
    }

    private func sanitizedCollectedWeight(_ rawWeight: Double) -> Double {
        guard rawWeight.isFinite else { return weight }
        if weightBaseline == nil {
            weightBaseline = rawWeight
        }
        let collected = max(0, rawWeight - (weightBaseline ?? 0))
        let maximum = max(expectedCupYield + 80, Double(recipe.totalWater) + 80)
        guard collected <= maximum else { return weight }
        guard collected + 3 >= weight else { return weight }
        return max(weight, collected)
    }

    private func updateActivePour(for deliveredWater: Double) {
        var cumulative = 0.0
        for (index, pour) in recipe.pours.enumerated() {
            cumulative += Double(pour.volume)
            if deliveredWater <= cumulative {
                activePourIndex = index
                return
            }
        }
        activePourIndex = max(0, recipe.pours.count - 1)
    }

    private var liveStageTitle: String {
        switch machine.telemetry.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .idle: "Preparing"
        case .grinding: "Grinding beans"
        case .brewing: activePourIndex == 0 ? "Blooming" : "Pour \(activePourIndex + 1)"
        case .paused: "Resting"
        case .complete: "Brew complete"
        case .error: "Machine needs attention"
        }
    }

    private var liveActivityPhase: BrewProgramPhase {
        switch machine.telemetry.state {
        case .connecting, .idle: .preparing
        case .disconnected: .error
        case .grinding: .grinding
        case .brewing:
            if water < 0.5 { .heating }
            else { activePourIndex == 0 ? .blooming : .pouring }
        case .paused: .resting
        case .complete: .complete
        case .error: .error
        }
    }

    private func stageTitle(for phase: BrewProgramPhase) -> String {
        switch phase {
        case .preparing: "Preparing brewer"
        case .grinding: "Grinding beans"
        case .heating: "Heating water"
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
        case .preparing: "cup.and.saucer.fill"
        case .grinding: "circle.grid.cross.fill"
        case .heating: "thermometer.high"
        case .blooming: "drop.circle.fill"
        case .pouring: "water.waves"
        case .resting: "pause.fill"
        case .complete: "checkmark"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var phaseTint: Color {
        return switch currentPhase {
        case .grinding: Color(red: 0.80, green: 0.61, blue: 0.43)
        case .heating: .orange
        case .blooming, .pouring: StudioTheme.accent
        case .resting: Color(red: 0.66, green: 0.72, blue: 0.94)
        case .complete: StudioTheme.mint
        case .error: .red
        case .preparing: StudioTheme.muted
        }
    }

    private var preparationDetail: String {
        return switch currentPhase {
        case .grinding: "Grinding \(Int(recipe.dose.rounded())) g at \(recipe.rpm.rawValue) RPM"
        case .heating: "Bringing the brewer to the first pour temperature"
        case .resting: "Letting the coffee bed drain before the next pour"
        default: "Preparing the simulated machine workflow"
        }
    }

    private func activityState(phase: BrewProgramPhase) -> BrewActivityAttributes.ContentState {
        let currentPour = [.blooming, .pouring, .resting].contains(phase) ? activePourIndex + 1 : 0
        return BrewActivityAttributes.ContentState(
            phase: phase,
            stageTitle: phase == liveActivityPhase && mode == .live ? liveStageTitle : stageTitle(for: phase),
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
            stage = "Brew stopped"
            finished = true
            Task {
                await BrewLiveActivityManager.shared.end(
                    with: activityState(phase: .error),
                    success: false
                )
            }
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
