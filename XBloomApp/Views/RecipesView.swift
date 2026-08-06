import SwiftData
import SwiftUI
import XBloomCore

enum RecipeLibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case hot = "Hot"
    case iced = "Iced"

    var id: String { rawValue }

    func includes(_ recipe: Recipe) -> Bool {
        switch self {
        case .all: true
        case .hot: recipe.brewStyle == .hot
        case .iced: recipe.brewStyle == .iced
        }
    }
}

struct RecipeLibraryFilterPicker: View {
    @Binding var selection: RecipeLibraryFilter

    var body: some View {
        Picker("Recipe type", selection: $selection) {
            ForEach(RecipeLibraryFilter.allCases) { filter in
                Label(
                    filter.rawValue,
                    systemImage: filter == .iced
                        ? "snowflake"
                        : filter == .hot ? "sun.max.fill" : "square.grid.2x2.fill"
                )
                .tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Filters the recipe library by hot or iced pour-over")
    }
}

struct RecipesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredRecipe.updatedAt, order: .reverse) private var recipes: [StoredRecipe]
    @State private var draft: Recipe?
    @State private var searchText = ""
    @State private var selectedFilter: RecipeLibraryFilter = .all

    private var filteredRecipes: [StoredRecipe] {
        recipes.filter { stored in
            if selectedFilter != .all,
               let style = stored.indexedBrewStyle,
               (selectedFilter == .hot ? style != .hot : style != .iced) {
                return false
            }
            guard let recipe = stored.recipe, selectedFilter.includes(recipe) else { return false }
            return recipe.matchesLibrarySearch(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    LazyVStack(spacing: 14) {
                        recipeSearchField

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recipe library")
                                    .font(.title2.weight(.bold))
                                Text("Programs ready for your xBloom")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(title: "\(recipes.count) saved", color: AppTheme.coffee, systemImage: "bookmark.fill")
                        }
                        .padding(.bottom, 4)

                        RecipeLibraryFilterPicker(selection: $selectedFilter)
                            .padding(.bottom, 4)

                        if filteredRecipes.isEmpty {
                            ContentUnavailableView(
                                searchText.isEmpty ? "No \(selectedFilter.rawValue.lowercased()) recipes" : "No recipes found",
                                systemImage: searchText.isEmpty ? "cup.and.saucer" : "magnifyingglass",
                                description: Text(
                                    searchText.isEmpty
                                        ? "Create a recipe to add it to this collection."
                                        : "Try a different name, roaster, origin, or recipe type."
                                )
                            )
                            .frame(minHeight: 320)
                        }

                        ForEach(filteredRecipes) { stored in
                            if let recipe = stored.recipe {
                                VStack(spacing: 0) {
                                    NavigationLink {
                                        RecipeDetailView(stored: stored, recipe: recipe)
                                    } label: {
                                        RecipeRow(recipe: recipe)
                                            .padding(16)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(.white.opacity(0.08), lineWidth: 1)
                                }
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        modelContext.delete(stored)
                                        try? modelContext.save()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                MachineToolbar()
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        draft = Recipe(
                            name: "",
                            pours: [
                                PourStep(volume: 50, temperature: 93, pauseAfter: 30),
                                PourStep(volume: 120, temperature: 93, flowRate: 3.3),
                                PourStep(volume: 118, temperature: 92, flowRate: 3.5),
                            ]
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $draft) { recipe in
                RecipeEditorView(recipe: recipe) { saved in
                    modelContext.insert(StoredRecipe(recipe: saved))
                    try? modelContext.save()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var recipeSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(StudioTheme.muted)
            TextField("Search recipes", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(StudioTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear recipe search")
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

extension Recipe {
    func matchesLibrarySearch(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return [
            name,
            roaster,
            origin,
            aiDescription ?? "",
            brewStyle == .iced ? "iced cold pour-over" : "hot pour-over",
        ]
        .contains { $0.localizedCaseInsensitiveContains(normalized) }
    }
}

struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(recipeTint)

                Text(recipe.brewStyle == .iced ? "ICED" : "HOT")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.black.opacity(0.43))
                    .padding(12)

                Text("\(recipe.pours.count)")
                    .font(.system(size: 56, weight: .light, design: .rounded))
                    .foregroundStyle(.black.opacity(0.30))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 11)
                    .padding(.bottom, 2)

                PourPatternMark(
                    pattern: recipe.pours.first?.pattern ?? .center,
                    color: .black.opacity(0.42),
                    size: 21
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(12)
            }
            .frame(width: 92, height: 108)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(recipe.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if recipe.generatedByAI {
                        Label("AI", systemImage: "sparkles")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(StudioTheme.accent, in: Capsule())
                    }
                    Spacer()
                }

                Text(primaryStats)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                HStack(spacing: 6) {
                    Image(systemName: recipe.brewStyle == .iced ? "snowflake" : "sun.max.fill")
                    Text(recipe.brewStyle == .iced ? "Iced pour-over" : "Hot pour-over")
                    if recipe.brewStyle == .iced, recipe.iceGrams > 0 {
                        Text("·")
                        Text("\(recipe.iceGrams) g ice")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(recipe.brewStyle == .iced ? .cyan : AppTheme.crema)

                Text(sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.35))
        }
        .contentShape(Rectangle())
    }

    private var recipeTint: Color {
        switch recipe.pours.count {
        case 0...3: Color(red: 0.64, green: 0.73, blue: 0.86)
        case 4: StudioTheme.accent
        default: Color(red: 0.82, green: 0.72, blue: 0.48)
        }
    }

    private var primaryStats: String {
        "1:\(compactNumber(recipe.ratio)) | \(compactNumber(recipe.dose)) g | \(recipe.totalWater) ml | \(recipe.pours.count) pours"
    }

    private func compactNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private var sourceTitle: String {
        let source = [recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · ")
        return source.isEmpty ? "Saved on this iPhone" : source
    }
}

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(BrewSessionCoordinator.self) private var brewSession
    let stored: StoredRecipe
    @State var recipe: Recipe
    @State private var editing: Recipe?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                VStack(spacing: 18) {
                    detailIdentity
                    coffeeSummary
                    pourOverview
                    aiInsight
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    editing = recipe
                } label: {
                    Image(systemName: "pencil")
                        .font(.title3.weight(.bold))
                        .frame(width: 54, height: 54)
                        .background(StudioTheme.raised, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    if machine.isConnected {
                        brewSession.present(recipe: recipe, mode: .live)
                    } else {
                        machine.connect()
                    }
                } label: {
                    Label(machine.isConnected ? "Start brew" : "Connect to brew", systemImage: machine.isConnected ? "play.fill" : "bolt.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(StudioTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(machine.isSendingRecipe)

                Button {
                    brewSession.present(recipe: recipe, mode: .simulation)
                } label: {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.title3.weight(.bold))
                        .frame(width: 54, height: 54)
                        .background(StudioTheme.raised, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .padding(.top, 10)
            .background(.ultraThinMaterial)
        }
        .alert("Brew error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $editing) { value in
            RecipeEditorView(recipe: value) { updated in
                recipe = updated
                stored.update(with: updated)
                try? modelContext.save()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var detailIdentity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Label(
                            recipe.brewStyle == .iced ? "ICED POUR-OVER" : "HOT POUR-OVER",
                            systemImage: recipe.brewStyle == .iced ? "snowflake" : "sun.max.fill"
                        )
                            .font(.caption2.weight(.heavy))
                            .tracking(1.4)
                            .foregroundStyle(.black.opacity(0.52))
                        if recipe.generatedByAI {
                            Label("AI", systemImage: "sparkles")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(recipe.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text([recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.black.opacity(0.56))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: -5) {
                    Text("POURS")
                        .font(.caption2.bold())
                        .foregroundStyle(.black.opacity(0.36))
                        .fixedSize(horizontal: true, vertical: false)
                    Text("\(recipe.pours.count)")
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .foregroundStyle(.black.opacity(0.25))
                }
                .frame(minWidth: 62, alignment: .trailing)
            }
            HStack(alignment: .center, spacing: 8) {
                Text("1:\(String(format: "%.1f", recipe.ratio))")
                Rectangle().fill(.black.opacity(0.28)).frame(width: 1, height: 28)
                Text("\(recipe.totalWater) ml")
                if recipe.brewStyle == .iced, recipe.iceGrams > 0 {
                    Rectangle().fill(.black.opacity(0.28)).frame(width: 1, height: 28)
                    Label("\(recipe.iceGrams) g ice", systemImage: "snowflake")
                        .foregroundStyle(.black.opacity(0.56))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(.black.opacity(0.76))
        .padding(16)
        .background(
            LinearGradient(colors: [StudioTheme.accent, Color(red: 0.52, green: 0.70, blue: 0.71)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.top, 8)
    }

    private var coffeeSummary: some View {
        HStack(spacing: 0) {
            compactMetric("Dose", "\(String(format: "%.1f", recipe.dose)) g")
            summaryDivider
            compactMetric("Grind", recipe.useGrinder ? "\(recipe.grindSize)" : "Off")
            summaryDivider
            compactMetric("RPM", recipe.useGrinder ? "\(recipe.rpm.rawValue)" : "—")
        }
        .padding(.vertical, 13)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var pourOverview: some View {
        StudioCard(accent: StudioTheme.accent) {
            VStack(alignment: .leading, spacing: 18) {
                StudioSectionTitle(
                    title: "Pours",
                    detail: "\(recipe.pours.count) steps · \(recipe.totalWater) ml",
                    icon: "drop.fill"
                )

                GeometryReader { proxy in
                    let spacing: CGFloat = 6
                    let count = max(1, recipe.pours.count)
                    let availableWidth = proxy.size.width - (spacing * CGFloat(count - 1))
                    let fittedWidth = availableWidth / CGFloat(count)
                    let itemWidth = max(58, fittedWidth)

                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(Array(recipe.pours.enumerated()), id: \.element.id) { index, pour in
                                pourBar(index: index, pour: pour, width: itemWidth)
                            }
                        }
                        .frame(minWidth: proxy.size.width, alignment: .center)
                        .padding(.top, 4)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(height: 252)
            }
        }
    }

    @ViewBuilder
    private var aiInsight: some View {
        if recipe.generatedByAI, let description = recipe.aiDescription, !description.isEmpty {
            StudioCard(accent: StudioTheme.mint) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Label("AI barista insight", systemImage: "sparkles")
                            .font(.headline)
                        Spacer()
                        Text("GEMINI")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.1)
                            .foregroundStyle(StudioTheme.mint)
                    }
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(StudioTheme.accent)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 45)
    }

    private func pourBar(index: Int, pour: PourStep, width: CGFloat) -> some View {
        let maxVolume = max(1, recipe.pours.map(\.volume).max() ?? 1)
        let fraction = CGFloat(pour.volume) / CGFloat(maxVolume)
        let height = 82 + (78 * fraction)

        return VStack(spacing: 8) {
            Text("\(pour.volume) ml")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [pourTint(index).opacity(0.42), pourTint(index).opacity(0.18)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(pourTint(index))
                            .frame(height: 3)
                            .clipShape(Capsule())
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                    }

                VStack(spacing: 7) {
                    PourPatternMark(pattern: pour.pattern, color: pourTint(index), size: 30)
                    Text(patternTitle(pour.pattern))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                if pour.agitationBefore {
                    agitationMarker("B")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                if pour.agitationAfter {
                    agitationMarker("A")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .frame(width: max(48, width - 8), height: height)

            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                Text("\(pour.temperature)°C")
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))

            Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                .font(.caption.weight(.bold))
                .lineLimit(1)

            Label("\(pour.pauseAfter)s rest", systemImage: "pause.fill")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(StudioTheme.muted)
                .lineLimit(1)
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(index == 0 ? "Bloom" : "Pour \(index + 1)"), \(pour.volume) milliliters, \(pour.temperature) degrees, \(patternTitle(pour.pattern)), \(pour.pauseAfter) seconds rest"
        )
    }

    private func agitationMarker(_ timing: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "water.waves")
                .font(.system(size: 9, weight: .heavy))
            Text(timing)
                .font(.system(size: 7, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.black.opacity(0.74))
        .frame(width: 25, height: 25)
        .background(StudioTheme.mint, in: Circle())
        .overlay { Circle().stroke(.black.opacity(0.18), lineWidth: 1) }
    }

    private func pourTint(_ index: Int) -> Color {
        let colors: [Color] = [StudioTheme.accent, StudioTheme.mint, AppTheme.crema, .cyan, .indigo]
        return colors[index % colors.count]
    }

    private func patternTitle(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Centered"
        case .circular: "Circular"
        case .spiral: "Spiral"
        }
    }
}

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var recipe: Recipe
    @State private var expandedPourID: UUID?
    let onSave: (Recipe) -> Void

    private let parameterColumns = [
        GridItem(.flexible()),
    ]

    private var issues: [ValidationIssue] {
        RecipeValidator.validate(recipe)
    }

    private var canSave: Bool {
        !issues.contains { $0.severity == .error }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    // These cards are highly interactive and their values update
                    // frequently. Keeping them resident avoids LazyVStack
                    // re-anchoring the scroll position when a pattern or agitation
                    // value changes.
                    VStack(spacing: 20) {
                        recipeIdentity
                        coffeeSettings
                        poursEditor
                        validationCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Coffee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            .safeAreaInset(edge: .bottom) {
                StudioSaveBar(
                    title: "Save",
                    subtitle: saveMessage,
                    enabled: canSave
                ) {
                    onSave(recipe)
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if recipe.brewStyle == .cold {
                recipe.brewStyle = .iced
            }
        }
        .onChange(of: recipe.brewStyle) { _, style in
            if style == .hot {
                recipe.iceGrams = 0
            }
        }
    }

    private var recipeIdentity: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECIPE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(.black.opacity(0.55))
                    TextField("Name your recipe", text: $recipe.name)
                        .font(.title2.weight(.bold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.black)
                }
                Spacer()
                Text("\(recipe.pours.count)")
                    .font(.system(size: 68, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black.opacity(0.26))
                    .overlay(alignment: .topTrailing) {
                        Text("POURS")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black.opacity(0.36))
                    }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("1:\(String(format: "%.1f", recipe.ratio))")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Rectangle()
                    .fill(.black.opacity(0.28))
                    .frame(width: 1, height: 34)
                Text("\(recipe.totalWater) ml")
                    .font(.title.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(.black.opacity(0.76))
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [StudioTheme.accent, Color(red: 0.52, green: 0.70, blue: 0.71)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        }
        .padding(.top, 8)
    }

    private var coffeeSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Coffee")
                    .font(.largeTitle.weight(.semibold))
            }

            StudioCard {
                VStack(spacing: 14) {
                    GrinderPowerControl(isOn: $recipe.useGrinder)

                    Picker("Brew style", selection: $recipe.brewStyle) {
                        Text("Hot pour-over").tag(BrewStyle.hot)
                        Text("Iced pour-over").tag(BrewStyle.iced)
                    }
                    .pickerStyle(.segmented)

                    StudioTextField(title: "Roaster", text: $recipe.roaster, icon: "building.2")
                    StudioTextField(title: "Origin & process", text: $recipe.origin, icon: "globe.americas")

                    LazyVGrid(columns: parameterColumns, spacing: 12) {
                        StudioDialBox(
                            title: "Dose",
                            value: Binding(
                                get: { recipe.dose },
                                set: { recipe.dose = $0 }
                            ),
                            range: 5...30,
                            step: 0.5,
                            unit: "g",
                            decimals: 1
                        )

                        StudioDialBox(
                            title: "Coffee : water",
                            value: Binding(
                                get: { recipe.ratio },
                                set: { setTargetRatio($0) }
                            ),
                            range: recipe.brewStyle == .iced ? 7.5...20 : 12...20,
                            step: 0.1,
                            prefix: "1:",
                            decimals: 1,
                            tint: StudioTheme.mint
                        )

                        if recipe.brewStyle == .iced {
                            StudioDialBox(
                                title: "Ice",
                                value: Binding(
                                    get: { Double(recipe.iceGrams) },
                                    set: { recipe.iceGrams = Int($0.rounded()) }
                                ),
                                range: 0...500,
                                step: 5,
                                unit: "g",
                                tint: Color.cyan
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        StudioDialBox(
                            title: "Grind size",
                            value: Binding(
                                get: { Double(recipe.grindSize) },
                                set: { recipe.grindSize = Int($0.rounded()) }
                            ),
                            range: 1...80,
                            unit: "",
                            tint: Color(red: 0.77, green: 0.62, blue: 0.43)
                        )
                        .opacity(recipe.useGrinder ? 1 : 0.42)
                        .allowsHitTesting(recipe.useGrinder)

                        StudioDialBox(
                            title: "Grinder speed",
                            value: Binding(
                                get: { Double(recipe.rpm.rawValue) },
                                set: { setRPM($0) }
                            ),
                            range: 60...120,
                            step: 10,
                            unit: "RPM",
                            tint: Color(red: 0.53, green: 0.62, blue: 0.86)
                        )
                        .opacity(recipe.useGrinder ? 1 : 0.42)
                        .allowsHitTesting(recipe.useGrinder)
                    }
                }
            }
        }
    }

    private var poursEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text("Pours")
                    .font(.largeTitle.weight(.semibold))
                Text("\(recipe.totalWater)/500 ml")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(recipe.totalWater > 500 ? .orange : StudioTheme.mint)
                Spacer()
                Button {
                    let newPour = PourStep(volume: 50, temperature: 92, flowRate: 3.2)
                    recipe.pours.append(newPour)
                    expandedPourID = newPour.id
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(StudioTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(recipe.pours.count >= 8)
            }

            ForEach(Array(recipe.pours.indices), id: \.self) { index in
                pourCard(index: index)
            }
        }
    }

    private func pourCard(index: Int) -> some View {
        let pour = recipe.pours[index]
        let expanded = expandedPourID == pour.id
        let percentage = recipe.totalWater > 0
            ? Int((Double(pour.volume) / Double(recipe.totalWater) * 100).rounded())
            : 0

        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    expandedPourID = expanded ? nil : pour.id
                }
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text("\(percentage)")
                                .font(.system(size: 48, weight: .light, design: .rounded))
                                .monospacedDigit()
                            Text("%")
                                .font(.title2.weight(.bold))
                        }
                    }
                    .frame(width: 105, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(pour.volume) ml", systemImage: "drop.fill")
                        HStack(spacing: 8) {
                            PourPatternMark(pattern: pour.pattern, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(patternTitle(pour.pattern))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text("\(pour.temperature)°C")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(StudioTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                        // Every pattern uses the same two-line footprint. This
                        // prevents "Spiral" fitting on one line while longer
                        // names wrap and change the card's height.
                        .frame(height: 42, alignment: .leading)
                        HStack(spacing: 12) {
                            Text("\(String(format: "%.1f", pour.flowRate)) ml/s")
                            Text("·")
                            Text("\(pour.pauseAfter)s rest")
                        }
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                        HStack(spacing: 6) {
                            Text("Agitation")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    (pour.agitationBefore || pour.agitationAfter)
                                        ? StudioTheme.mint
                                        : StudioTheme.muted
                                )
                            AgitationTimingMarks(
                                before: pour.agitationBefore,
                                after: pour.agitationAfter,
                                size: 20,
                                showInactive: true
                            )
                        }
                        .frame(height: 28)
                    }
                    .font(.headline.monospacedDigit())

                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.headline.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(StudioTheme.accent)
                }
                .contentShape(Rectangle())
                .padding(18)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(.white.opacity(0.10))
                pourDetails(index: index)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(expanded ? StudioTheme.accent : .white.opacity(0.08), lineWidth: expanded ? 2 : 1)
        }
    }

    private func pourDetails(index: Int) -> some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: parameterColumns, spacing: 12) {
                StudioDialBox(
                    title: "Volume",
                    value: Binding(
                        get: { Double(recipe.pours[index].volume) },
                        set: { recipe.pours[index].volume = Int($0.rounded()) }
                    ),
                    range: 0...240,
                    unit: "ml",
                    height: 84
                )
                StudioDialBox(
                    title: "Temperature",
                    value: Binding(
                        get: { Double(recipe.pours[index].temperature) },
                        set: { recipe.pours[index].temperature = Int($0.rounded()) }
                    ),
                    range: 80...96,
                    unit: "°C",
                    tint: .orange,
                    height: 84
                )
                StudioDialBox(
                    title: "Flow rate",
                    value: Binding(
                        get: { recipe.pours[index].flowRate },
                        set: { recipe.pours[index].flowRate = $0 }
                    ),
                    range: 3...3.5,
                    step: 0.1,
                    unit: "ml/s",
                    decimals: 1,
                    tint: .blue,
                    height: 84
                )
                StudioDialBox(
                    title: "Pause after",
                    value: Binding(
                        get: { Double(recipe.pours[index].pauseAfter) },
                        set: { recipe.pours[index].pauseAfter = Int($0.rounded()) }
                    ),
                    range: 0...120,
                    unit: "s",
                    tint: .purple,
                    height: 84
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Pour pattern")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                PourPatternSelector(
                    selection: Binding(
                        get: { recipe.pours[index].pattern },
                        set: { recipe.pours[index].pattern = $0 }
                    )
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Agitation timing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                VStack(spacing: 10) {
                    agitationButton(
                        phase: .before,
                        isOn: recipe.pours[index].agitationBefore
                    ) {
                        setAgitation(
                            !recipe.pours[index].agitationBefore,
                            phase: .before,
                            at: index
                        )
                    }
                    agitationButton(
                        phase: .after,
                        isOn: recipe.pours[index].agitationAfter
                    ) {
                        setAgitation(
                            !recipe.pours[index].agitationAfter,
                            phase: .after,
                            at: index
                        )
                    }
                }
            }

            if recipe.pours.count > 1 {
                Button(role: .destructive) {
                    let removedID = recipe.pours[index].id
                    recipe.pours.remove(at: index)
                    if expandedPourID == removedID { expandedPourID = nil }
                } label: {
                    Label("Remove this pour", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private func agitationButton(
        phase: AgitationPhase,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AgitationPhaseMark(phase: phase, active: isOn, size: 27)
                    .frame(width: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase == .before ? "Before pour" : "After pour")
                        .font(.subheadline.weight(.bold))
                    Text(phase == .before ? "Agitate, then begin pouring" : "Agitate after this pour finishes")
                        .font(.caption)
                        .foregroundStyle(isOn ? .black.opacity(0.62) : StudioTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                Text(isOn ? "ON" : "OFF")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        isOn ? Color.black.opacity(0.10) : Color.white.opacity(0.06),
                        in: Capsule()
                    )
            }
            .foregroundStyle(isOn ? .black : .white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                isOn ? StudioTheme.accent : StudioTheme.raised,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func setAgitation(_ enabled: Bool, phase: AgitationPhase, at index: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch phase {
            case .before:
                recipe.pours[index].agitationBefore = enabled
            case .after:
                recipe.pours[index].agitationAfter = enabled
            }
        }
    }

    @ViewBuilder
    private var validationCard: some View {
        if !issues.isEmpty {
            StudioCard(accent: issues.contains(where: { $0.severity == .error }) ? .red : .orange) {
                VStack(alignment: .leading, spacing: 10) {
                    StudioSectionTitle(title: "Recipe checks", icon: "checkmark.shield")
                    ForEach(issues) { issue in
                        Label(
                            issue.message,
                            systemImage: issue.severity == .error
                                ? "xmark.octagon.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                    }
                }
            }
        }
    }

    private var saveMessage: String {
        if let error = issues.first(where: { $0.severity == .error }) {
            return error.message
        }
        if let warning = issues.first {
            return warning.message
        }
        return "\(recipe.totalWater) ml · 1:\(String(format: "%.1f", recipe.ratio)) · \(recipe.pours.count) pours"
    }

    private func setRPM(_ rawValue: Double) {
        let choices = GrinderRPM.allCases.filter { $0 != .off }
        recipe.rpm = choices.min {
            abs(Double($0.rawValue) - rawValue) < abs(Double($1.rawValue) - rawValue)
        } ?? .rpm80
    }

    private func setTargetRatio(_ ratio: Double) {
        guard !recipe.pours.isEmpty else { return }
        let desiredWater = max(1, min(500, Int((recipe.dose * ratio).rounded())))
        let currentWater = max(1, recipe.totalWater)
        var volumes = recipe.pours.map {
            min(240, max(0, Int((Double($0.volume) / Double(currentWater) * Double(desiredWater)).rounded())))
        }
        var difference = desiredWater - volumes.reduce(0, +)
        var index = volumes.count - 1
        var attempts = 0
        while difference != 0 && attempts < 2_000 {
            if difference > 0, volumes[index] < 240 {
                volumes[index] += 1
                difference -= 1
            } else if difference < 0, volumes[index] > 0 {
                volumes[index] -= 1
                difference += 1
            }
            index = index == 0 ? volumes.count - 1 : index - 1
            attempts += 1
        }
        for index in recipe.pours.indices {
            recipe.pours[index].volume = volumes[index]
        }
    }

    private func patternTitle(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Centered"
        case .circular: "Circular"
        case .spiral: "Spiral"
        }
    }

    private func patternIcon(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "circle.circle.fill"
        case .circular: "circle.dotted"
        case .spiral: "tropicalstorm"
        }
    }
}
