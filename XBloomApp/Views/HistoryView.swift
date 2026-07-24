import Charts
import SwiftData
import SwiftUI
import XBloomCore

struct HistoryView: View {
    @Query(sort: \StoredBrew.completedAt, order: .reverse) private var history: [StoredBrew]

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Brew journal")
                                .font(.title2.weight(.bold))
                            Text("Every cup, stored on this iPhone")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(title: "\(history.count) brews", color: AppTheme.coffee, systemImage: "clock.fill")
                    }
                    .padding(.bottom, 4)

                    ForEach(history) { brew in
                        NavigationLink {
                            BrewHistoryDetailView(brew: brew)
                        } label: {
                            historyCard(brew)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            if history.isEmpty {
                ContentUnavailableView(
                    "No brew history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("A completed machine brew will be recorded locally.")
                )
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { MachineToolbar() }
    }

    private func historyCard(_ brew: StoredBrew) -> some View {
        let entry = brew.entry
        let recipe = entry?.recipeSnapshot

        return HStack(spacing: 15) {
            IconBadge(
                systemImage: recipe?.generatedByAI == true ? "sparkles" : "waveform.path.ecg",
                tint: recipe?.generatedByAI == true ? StudioTheme.accent : AppTheme.coffee,
                size: 50
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(brew.recipeName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if recipe?.generatedByAI == true {
                        Text("AI")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(StudioTheme.accent, in: Capsule())
                    }
                }
                Text(brew.beanName ?? brew.completedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let recipe {
                    Text("\(styleTitle(recipe.brewStyle)) · \(recipe.servings ?? 1) cup\(recipe.servings == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(recipe.brewStyle == .iced ? .cyan : AppTheme.crema)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                if let rating = entry?.rating {
                    Label("\(rating)/5", systemImage: "star.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.crema)
                } else {
                    Text(formatDuration(brew.duration))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(brew.completedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .appCard()
    }
}

struct BrewHistoryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GeminiService.self) private var gemini
    @Query private var storedRecipes: [StoredRecipe]
    @Query private var storedBeans: [StoredBean]

    let brew: StoredBrew

    @State private var rating: Int
    @State private var selectedFeedback: Set<String>
    @State private var selectedGoals: Set<RecipeFlavorGoal>
    @State private var notes: String
    @State private var isEnhancing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var enhancedRecipeID: UUID?
    @State private var enhancementTask: Task<Void, Never>?

    init(brew: StoredBrew) {
        self.brew = brew
        let entry = brew.entry
        _rating = State(initialValue: entry?.rating ?? 0)
        _selectedFeedback = State(initialValue: Set(entry?.feedbackTags ?? []))
        _selectedGoals = State(
            initialValue: Set(
                (entry?.enhancementGoals ?? []).compactMap(RecipeFlavorGoal.init(rawValue:))
            )
        )
        _notes = State(initialValue: entry?.notes ?? "")
        _enhancedRecipeID = State(initialValue: entry?.enhancedRecipeID)
    }

    private var entry: BrewHistoryEntry? { brew.entry }

    private var originalRecipe: Recipe? {
        if let snapshot = entry?.recipeSnapshot { return snapshot }
        guard let id = entry?.recipeID else { return nil }
        return storedRecipes.first(where: { $0.id == id })?.recipe
    }

    private var originalBean: BeanProfile? {
        if let snapshot = entry?.beanSnapshot { return snapshot }
        guard let id = entry?.beanID else { return nil }
        return storedBeans.first(where: { $0.id == id })?.profile
    }

    private var enhancedRecipe: Recipe? {
        guard let enhancedRecipeID else { return nil }
        return storedRecipes.first(where: { $0.id == enhancedRecipeID })?.recipe
    }

    private var canEnhance: Bool {
        originalRecipe?.generatedByAI == true
            && originalBean != nil
            && rating > 0
            && (
                !selectedFeedback.isEmpty
                    || !selectedGoals.isEmpty
                    || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            && gemini.hasAPIKey
            && !isEnhancing
    }

    private let feedbackOptions = [
        "Too sour",
        "Too bitter",
        "Too weak",
        "Too strong",
        "Dry finish",
        "Flat or dull",
        "Not sweet enough",
        "Needs more clarity",
        "Needs more body",
        "Brewed too fast",
        "Brewed too slow",
        "Already close",
    ]

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    resultHero
                    resultMetrics

                    if let recipe = originalRecipe {
                        recipeContext(recipe)
                        if recipe.generatedByAI {
                            enhancementStudio(recipe)
                        } else {
                            feedbackOnlyCard
                        }
                    } else {
                        missingRecipeCard
                    }

                    if let enhancedRecipe {
                        enhancedRecipeCard(enhancedRecipe)
                    }

                    telemetryCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(brew.recipeName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onDisappear {
            enhancementTask?.cancel()
            enhancementTask = nil
        }
        .alert("Could not enhance recipe", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var resultHero: some View {
        StudioCard(accent: originalRecipe?.generatedByAI == true ? StudioTheme.accent : AppTheme.crema) {
            HStack(spacing: 15) {
                Image(systemName: originalRecipe?.generatedByAI == true ? "sparkles" : "cup.and.saucer.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 58, height: 58)
                    .background(originalRecipe?.generatedByAI == true ? StudioTheme.accent : AppTheme.crema, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text(originalRecipe?.generatedByAI == true ? "AI BREW RECORD" : "BREW RECORD")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(StudioTheme.accent)
                    Text(brew.recipeName)
                        .font(.title2.weight(.bold))
                    Text([entry?.beanName, brew.completedAt.formatted(date: .abbreviated, time: .shortened)]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                }
                Spacer()
            }
        }
    }

    private var resultMetrics: some View {
        HStack(spacing: 10) {
            MetricTile(title: "Duration", value: formatDuration(entry?.duration ?? brew.duration), icon: "timer", tint: StudioTheme.accent)
            MetricTile(title: "Water", value: "\(Int((entry?.water ?? 0).rounded())) ml", icon: "drop.fill", tint: .blue)
            MetricTile(title: "Yield", value: "\(String(format: "%.1f", entry?.coffeeWeight ?? 0)) g", icon: "scalemass.fill", tint: StudioTheme.mint)
        }
    }

    private func recipeContext(_ recipe: Recipe) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionTitle(title: "What you brewed", detail: styleTitle(recipe.brewStyle), icon: "doc.text.fill")
                if let bean = originalBean {
                    contextRow("Bean", value: bean.name, icon: "leaf.fill")
                    contextRow("Origin", value: [bean.country, bean.process].filter { !$0.isEmpty }.joined(separator: " · "), icon: "globe")
                }
                contextRow("Cup", value: "\(recipe.servings ?? 1) cup\(recipe.servings == 1 ? "" : "s") · \(styleTitle(recipe.brewStyle))", icon: recipe.brewStyle == .iced ? "snowflake" : "flame.fill")
                contextRow("Recipe", value: "\(String(format: "%.1f", recipe.dose)) g · \(recipe.totalWater) ml · 1:\(String(format: "%.1f", recipe.ratio))", icon: "cup.and.saucer.fill")
                contextRow("Grinder", value: recipe.useGrinder ? "\(recipe.grindSize) · \(recipe.rpm.rawValue) RPM" : "Off", icon: "circle.grid.cross.fill")
                contextRow("Pours", value: "\(recipe.pours.count) saved steps", icon: "drop.degreesign.fill")

                if let description = recipe.aiDescription, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(StudioTheme.muted)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func enhancementStudio(_ recipe: Recipe) -> some View {
        StudioCard(accent: StudioTheme.accent) {
            VStack(alignment: .leading, spacing: 18) {
                StudioSectionTitle(title: "Enhance this recipe", detail: "Gemini", icon: "wand.and.sparkles")
                Text("The bean, \(styleTitle(recipe.brewStyle).lowercased()), cups, original settings, and measured brew are already attached. Describe what happened, then combine the goals you want in the improved cup.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)

                VStack(alignment: .leading, spacing: 10) {
                    Text("How was this cup?")
                        .font(.headline)
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { value in
                            Button {
                                rating = value
                            } label: {
                                Image(systemName: value <= rating ? "star.fill" : "star")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(value <= rating ? AppTheme.crema : StudioTheme.muted)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(
                                        value == rating ? AppTheme.crema.opacity(0.13) : StudioTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(value) out of 5")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("What should change?")
                        .font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(feedbackOptions.prefix(6), id: \.self) { feedbackChip($0) }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(feedbackOptions.suffix(from: 6), id: \.self) { feedbackChip($0) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("What should the new cup aim for?")
                        .font(.headline)
                    Text("Choose as many compatible goals as you want.")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(RecipeFlavorGoal.allCases.prefix(6))) { goal in
                                StudioFlavorGoalChip(
                                    goal: goal,
                                    selected: selectedGoals.contains(goal)
                                ) {
                                    selectedGoals = RecipeFlavorGoal.toggling(goal, in: selectedGoals)
                                }
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(RecipeFlavorGoal.allCases.suffix(from: 6))) { goal in
                                StudioFlavorGoalChip(
                                    goal: goal,
                                    selected: selectedGoals.contains(goal)
                                ) {
                                    selectedGoals = RecipeFlavorGoal.toggling(goal, in: selectedGoals)
                                }
                            }
                        }
                    }
                    Label(
                        "Direct opposites replace each other: Bright ↔ Low acidity, Tea-like ↔ Full body.",
                        systemImage: "arrow.left.arrow.right"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Your tasting note", systemImage: "text.quote")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.muted)
                    TextField(
                        "Example: floral aroma was good, but the finish became dry and thin.",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .padding(14)
                    .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 16))
                }

                if !gemini.hasAPIKey {
                    Label("Add your Gemini API key in Settings to create an enhanced recipe.", systemImage: "key.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(StudioTheme.mint)
                }

                HStack(spacing: 10) {
                    Button {
                        saveFeedback()
                    } label: {
                        Label("Save feedback", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(StudioTheme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(rating == 0)

                    Button {
                        enhancementTask?.cancel()
                        enhancementTask = Task { await enhance(recipe) }
                    } label: {
                        HStack(spacing: 8) {
                            if isEnhancing { ProgressView().tint(.black) }
                            Label(isEnhancing ? "Enhancing…" : "Enhance", systemImage: "sparkles")
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(StudioTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canEnhance)
                    .opacity(canEnhance ? 1 : 0.45)
                }
            }
        }
    }

    private var feedbackOnlyCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                StudioSectionTitle(title: "Cup feedback", icon: "star.bubble.fill")
                Text("AI enhancement is available for recipes originally designed with Gemini.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    private var missingRecipeCard: some View {
        StudioCard(accent: .orange) {
            Label(
                "This older history entry does not contain a recipe snapshot, and its original recipe is no longer in the library.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func enhancedRecipeCard(_ recipe: Recipe) -> some View {
        StudioCard(accent: StudioTheme.mint) {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(title: "Enhanced recipe saved", detail: "New recipe", icon: "checkmark.seal.fill")
                Text(recipe.name)
                    .font(.title3.weight(.bold))
                Text(recipe.aiDescription ?? "Gemini created a new version from this brew feedback.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                Label("The original recipe remains unchanged. Find this version in Recipes and Brew.", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.mint)
            }
        }
    }

    @ViewBuilder
    private var telemetryCard: some View {
        if let entry, !entry.samples.isEmpty {
            StudioCard(accent: StudioTheme.mint) {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSectionTitle(title: "Extraction record", detail: "\(entry.samples.count) readings", icon: "chart.xyaxis.line")
                    Chart(entry.samples, id: \.elapsed) { sample in
                        LineMark(
                            x: .value("Seconds", sample.elapsed),
                            y: .value("Weight", sample.coffeeWeight)
                        )
                        .foregroundStyle(StudioTheme.mint)
                    }
                    .frame(height: 220)
                    .chartXAxisLabel("Elapsed time")
                    .chartYAxisLabel("g")
                }
            }
        }
    }

    private func feedbackChip(_ title: String) -> some View {
        let selected = selectedFeedback.contains(title)
        return Button {
            if selected {
                selectedFeedback.remove(title)
            } else {
                selectedFeedback.insert(title)
            }
        } label: {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? .black : .white.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(selected ? StudioTheme.accent : StudioTheme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func contextRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 28)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
            Spacer()
            Text(value.isEmpty ? "Not recorded" : value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private func saveFeedback(enhancedID: UUID? = nil) {
        guard var value = entry else { return }
        value.rating = rating == 0 ? nil : rating
        value.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        value.feedbackTags = selectedFeedback.sorted()
        value.enhancementGoals = selectedGoals.map(\.rawValue).sorted()
        if let enhancedID {
            value.enhancedRecipeID = enhancedID
        }
        brew.update(with: value)
        do {
            try modelContext.save()
            statusMessage = enhancedID == nil ? "Feedback saved to this brew." : "Feedback and enhanced recipe are linked."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func enhance(_ original: Recipe) async {
        guard let bean = originalBean, let entry, canEnhance else { return }
        isEnhancing = true
        errorMessage = nil
        statusMessage = nil
        defer { isEnhancing = false }

        do {
            let result = try await gemini.enhanceRecipe(
                original: original,
                bean: bean,
                brew: entry,
                rating: rating,
                feedbackTags: selectedFeedback.sorted(),
                goals: selectedGoals.map(\.rawValue).sorted(),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try Task.checkCancellation()
            var improved = try result.recipe(
                bean: bean,
                cups: original.servings ?? 1,
                requestedStyle: original.brewStyle == .iced ? .iced : .hot
            )
            improved.parentRecipeID = original.id
            improved.sourceBrewID = entry.id
            improved.generatedByAI = true
            modelContext.insert(StoredRecipe(recipe: improved))
            try modelContext.save()

            enhancedRecipeID = improved.id
            saveFeedback(enhancedID: improved.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func styleTitle(_ style: BrewStyle) -> String {
    style == .iced ? "Iced pour-over" : "Hot pour-over"
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded()))
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
}
