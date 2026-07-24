import Charts
import SwiftData
import SwiftUI
import XBloomCore

enum BrewSessionMode: String, Identifiable {
    case live
    case simulation

    var id: String { rawValue }
}

struct BrewView: View {
    @Query(sort: \StoredRecipe.updatedAt, order: .reverse) private var storedRecipes: [StoredRecipe]
    @Query(sort: \StoredBrew.completedAt, order: .reverse) private var brewHistory: [StoredBrew]
    @State private var searchText = ""
    @State private var selectedFilter: RecipeLibraryFilter = .all

    private var filteredRecipes: [StoredRecipe] {
        storedRecipes.filter { stored in
            guard let recipe = stored.recipe, selectedFilter.includes(recipe) else { return false }
            return recipe.matchesLibrarySearch(searchText)
        }
    }

    private var latestBrewDates: [UUID: Date] {
        brewHistory.reduce(into: [:]) { dates, brew in
            guard let recipeID = brew.entry?.recipeID else { return }
            if dates[recipeID] == nil {
                dates[recipeID] = brew.completedAt
            }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Query(sort: \StoredBean.updatedAt, order: .reverse) private var storedBeans: [StoredBean]

    let recipe: Recipe
    let mode: BrewSessionMode

    @State private var startedAt: Date?
    @State private var extractionStartedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var progress = 0.0
    @State private var stage = "Preparing"
    @State private var water = 0.0
    @State private var weight = 0.0
    @State private var temperature: Double?
    @State private var activePourIndex = 0
    @State private var samples: [BrewSample] = []
    @State private var errorMessage: String?
    @State private var hasStarted = false
    @State private var recordedCompletion = false
    @State private var finished = false
    @State private var lastSampleAt: TimeInterval = -.infinity

    private var estimatedDuration: TimeInterval {
        let preparation = recipe.useGrinder ? 35.0 : 15.0
        let pourDuration = recipe.pours.reduce(0.0) {
            $0 + Double($1.pauseBefore + $1.pauseAfter) + Double($1.volume) / max(0.1, $1.flowRate)
        }
        return preparation + pourDuration
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
            && machine.isConnected
            && machine.telemetry.state != .error
    }

    private var chartSamples: [BrewSample] {
        let renderSamples: [BrewSample]
        guard samples.count > 400 else {
            return BrewGraphSmoother.smooth(samples)
        }
        let step = max(1, Int(ceil(Double(samples.count) / 399)))
        var reduced = samples.enumerated().compactMap { index, sample in
            index.isMultiple(of: step) ? sample : nil
        }
        if reduced.last != samples.last, let last = samples.last {
            reduced.append(last)
        }
        renderSamples = reduced
        return BrewGraphSmoother.smooth(renderSamples)
    }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    extractionHero
                    sessionTiming
                    liveMetrics
                    if let activePour {
                        activePourCard(activePour)
                    }
                    extractionChart
                    pourTimeline
                    if mode == .live && !finished {
                        Button(role: .destructive) {
                            stopLiveBrew()
                        } label: {
                            Label("Stop brewing", systemImage: "stop.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
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
            if mode == .live && !isSessionLocked {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isSessionLocked)
        .task { await launchSession() }
        .onChange(of: machine.telemetry) {
            guard mode == .live else { return }
            captureTelemetry()
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
                    Image(systemName: finished ? "checkmark" : "drop.fill")
                        .font(.title2.weight(.bold))
                    Text("\(Int(progress * 100))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(finished ? StudioTheme.mint : StudioTheme.accent)
            }
            .frame(width: 132, height: 132)

            Text(stage)
                .font(.title2.weight(.bold))
            Text(mode == .simulation ? "Accelerated preview · no machine commands" : machine.machineName)
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
                    value: durationText(mode == .simulation ? elapsed : startedAt.map { context.date.timeIntervalSince($0) } ?? 0),
                    icon: "timer"
                )
                timingCell(title: "Estimated", value: durationText(estimatedDuration), icon: "hourglass")
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
                StudioSectionTitle(
                    title: "Live extraction",
                    detail: "Smoothed trend · \(samples.count) raw readings saved",
                    icon: "chart.xyaxis.line"
                )
                Chart(chartSamples, id: \.elapsed) { sample in
                    AreaMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("Water", sample.water)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [StudioTheme.accent.opacity(0.42), StudioTheme.accent.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("Water", sample.water)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(StudioTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    LineMark(
                        x: .value("Time", sample.elapsed),
                        y: .value("Coffee collected", sample.coffeeWeight)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(StudioTheme.mint)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                .frame(height: 190)
                .chartXAxisLabel("Elapsed time")
                .chartYAxisLabel("ml / g")

                HStack(spacing: 18) {
                    chartLegend("Water poured", color: StudioTheme.accent)
                    chartLegend("Coffee collected", color: StudioTheme.mint)
                }
            }
        }
    }

    private func chartLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 18, height: 4)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
        }
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
        startedAt = Date()
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
        } catch {
            errorMessage = error.localizedDescription
            stage = "Could not start"
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .error), success: false)
        }
    }

    @MainActor
    private func runSimulation() async {
        let totalSteps = 80
        for step in 0...totalSteps {
            guard !Task.isCancelled else { return }
            elapsed = estimatedDuration * Double(step) / Double(totalSteps)
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
            stage = stageTitle(for: estimate.phase)
            if estimate.extractionElapsed > 0, extractionStartedAt == nil {
                extractionStartedAt = Date()
            }
            samples.append(BrewSample(elapsed: elapsed, water: water, coffeeWeight: weight, temperature: temperature))
            await BrewLiveActivityManager.shared.update(
                activityState(phase: estimate.phase),
                force: estimate.phase == .complete
            )
            try? await Task.sleep(for: .milliseconds(95))
        }
        progress = 1
        finished = true
        stage = "Brew complete"
        await BrewLiveActivityManager.shared.end(with: activityState(phase: .complete), success: true)
    }

    private func captureTelemetry() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        water = machine.telemetry.waterVolume ?? water
        weight = machine.telemetry.weight ?? weight
        temperature = machine.telemetry.temperature ?? temperature
        var machinePhase = liveActivityPhase
        if machinePhase == .blooming || machinePhase == .pouring || machinePhase == .resting {
            if extractionStartedAt == nil {
                extractionStartedAt = Date()
            }
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            updateActivePour(for: water)
            machinePhase = liveActivityPhase
        } else if machinePhase != .complete {
            // Grinder and heater telemetry is preparation, not pour time.
            progress = 0
            activePourIndex = 0
        }
        stage = liveStageTitle
        appendLiveSampleIfNeeded(force: machine.telemetry.state == .complete)
        Task {
            await BrewLiveActivityManager.shared.update(
                activityState(phase: machinePhase),
                force: machine.telemetry.state == .complete
            )
        }

        if machine.telemetry.state == .disconnected, !finished, errorMessage == nil {
            errorMessage = "The xBloom disconnected during the brew. You can safely close this screen and reconnect."
        } else if machine.telemetry.state == .error, !finished, errorMessage == nil {
            errorMessage = "The xBloom reported an error. Check the machine, then close this screen and reconnect."
        }

        guard machine.telemetry.state == .complete, !recordedCompletion else { return }
        recordedCompletion = true
        finished = true
        progress = 1
        stage = "Brew complete"
        Task {
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .complete), success: true)
        }
        let bean = storedBeans.first { $0.id == recipe.beanID }
        do {
            try LocalLibrary.recordCompletedBrew(
                recipe: recipe,
                bean: bean,
                startedAt: startedAt,
                telemetry: machine.telemetry,
                samples: samples,
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

        // Four readings per second retain smooth history while keeping long
        // sessions bounded. The chart separately renders at most 400 points.
        if samples.count > 2_400 {
            samples.removeFirst(200)
        }
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
        case .brewing: activePourIndex == 0 ? .blooming : .pouring
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
            elapsedSeconds: Int(elapsed.rounded()),
            remainingSeconds: max(0, Int((estimatedDuration - elapsed).rounded()))
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
