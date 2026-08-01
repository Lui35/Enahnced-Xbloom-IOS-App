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
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search recipes"
            )
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
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.brewStyle.rawValue.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.black.opacity(0.48))
                Spacer()
                Text("\(recipe.pours.count)")
                    .font(.system(size: 54, weight: .light, design: .rounded))
                    .foregroundStyle(.black.opacity(0.46))
                Image(systemName: "arrow.down.to.line")
                    .font(.caption.bold())
                    .foregroundStyle(.black.opacity(0.4))
            }
            .padding(13)
            .frame(width: 105, height: 126, alignment: .leading)
            .background(recipeTint, in: RoundedRectangle(cornerRadius: 19, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(recipe.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if recipe.generatedByAI {
                        Label("AI", systemImage: "sparkles")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(StudioTheme.accent, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(StudioTheme.accent)
                }
                Text([recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    recipeStat(styleTitle, recipe.brewStyle == .iced ? "snowflake" : "sun.max.fill")
                    recipeStat(servingsTitle, "cup.and.saucer.fill")
                }
                HStack(spacing: 7) {
                    recipeStat("\(String(format: "%.1f", recipe.dose)) g", "scalemass")
                    recipeStat("\(recipe.totalWater) ml", "drop")
                }
                HStack(spacing: 7) {
                    recipeStat("1:\(String(format: "%.1f", recipe.ratio))", "percent")
                    recipeStat("Grind \(recipe.grindSize)", "circle.grid.cross")
                    if recipe.brewStyle == .iced {
                        recipeStat("\(recipe.iceGrams) g ice", "snowflake")
                    }
                }
                HStack(spacing: 7) {
                    ForEach(recipe.pours.prefix(4)) { pour in
                        VStack(spacing: 4) {
                            PourPatternMark(pattern: pour.pattern, size: 25)
                            if pour.agitationBefore || pour.agitationAfter {
                                AgitationTimingMarks(
                                    before: pour.agitationBefore,
                                    after: pour.agitationAfter,
                                    size: 13
                                )
                            }
                        }
                    }
                    if recipe.pours.count > 4 {
                        Text("+\(recipe.pours.count - 4)")
                            .font(.caption2.bold())
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
                if recipe.generatedByAI, let description = recipe.aiDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
            }
        }
    }

    private var recipeTint: Color {
        switch recipe.pours.count {
        case 0...3: Color(red: 0.64, green: 0.73, blue: 0.86)
        case 4: StudioTheme.accent
        default: Color(red: 0.82, green: 0.72, blue: 0.48)
        }
    }

    private func recipeStat(_ value: String, _ icon: String) -> some View {
        Label(value, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudioTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.white.opacity(0.06), in: Capsule())
    }

    private var styleTitle: String {
        recipe.brewStyle == .iced ? "Iced pour-over" : "Hot pour-over"
    }

    private var servingsTitle: String {
        let count = recipe.servings ?? 1
        return "\(count) cup\(count == 1 ? "" : "s")"
    }
}

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(BrewSessionCoordinator.self) private var brewSession
    let stored: StoredRecipe
    @State var recipe: Recipe
    @State private var editing: Recipe?
    @State private var expandedPourID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 20) {
                    detailIdentity

                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(
                            title: "Coffee",
                            detail: "\(recipe.brewStyle == .iced ? "Iced" : "Hot") · \(recipe.servings ?? 1) cup\(recipe.servings == 1 ? "" : "s")",
                            icon: "cup.and.saucer.fill"
                        )
                        detailMetric("Dose", "\(String(format: "%.1f", recipe.dose)) g", "scalemass.fill", StudioTheme.accent)
                        detailMetric("Coffee : water", "1:\(String(format: "%.1f", recipe.ratio))", "drop.degreesign.fill", StudioTheme.mint)
                        if recipe.brewStyle == .iced {
                            detailMetric("Ice", "\(recipe.iceGrams) g", "snowflake", .cyan)
                        }
                        detailMetric("Grind size", recipe.useGrinder ? "\(recipe.grindSize)" : "Grinder off", "circle.grid.cross.fill", AppTheme.crema)
                        detailMetric("Grinder speed", recipe.useGrinder ? "\(recipe.rpm.rawValue) RPM" : "—", "gauge.with.dots.needle.50percent", .indigo)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(title: "Pours", detail: "\(recipe.totalWater) ml", icon: "drop.fill")
                        ForEach(Array(recipe.pours.enumerated()), id: \.element.id) { index, pour in
                            detailPour(index: index, pour: pour)
                        }
                    }

                    StudioCard(accent: StudioTheme.mint) {
                        VStack(alignment: .leading, spacing: 12) {
                            StudioSectionTitle(title: "What happens next", icon: "play.circle.fill")
                            scenarioRow(1, "Recipe is validated and sent over Bluetooth.")
                            scenarioRow(2, recipe.useGrinder ? "The machine grinds \(String(format: "%.1f", recipe.dose)) g at \(recipe.rpm.rawValue) RPM." : "The machine skips grinding and prepares to brew.")
                            scenarioRow(3, "Water heats and each pour runs with its saved flow, temperature, pattern, and pause.")
                            scenarioRow(4, "Live weight, water, temperature, and progress appear in Brew Studio.")
                            scenarioRow(5, "The completed cup is saved locally in History.")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = recipe }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        editing = recipe
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(StudioTheme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        brewSession.present(recipe: recipe, mode: .simulation)
                    } label: {
                        Label("Simulate", systemImage: "play.rectangle.on.rectangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(StudioTheme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    if machine.isConnected {
                        brewSession.present(recipe: recipe, mode: .live)
                    } else {
                        machine.connect()
                    }
                } label: {
                    Label(machine.isConnected ? "Start brewing" : "Connect xBloom to brew", systemImage: machine.isConnected ? "play.fill" : "bolt.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(StudioTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(machine.isSendingRecipe)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                    VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("RECIPE")
                            .font(.caption2.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(.black.opacity(0.52))
                        if recipe.generatedByAI {
                            Label("GEMINI AI", systemImage: "sparkles")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(recipe.name)
                        .font(.title2.weight(.bold))
                    Text([recipe.roaster, recipe.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.black.opacity(0.56))
                }
                Spacer()
                Text("\(recipe.pours.count)")
                    .font(.system(size: 68, weight: .light, design: .rounded))
                    .foregroundStyle(.black.opacity(0.25))
                    .overlay(alignment: .topTrailing) {
                        Text("POURS")
                            .font(.caption2.bold())
                            .foregroundStyle(.black.opacity(0.36))
                    }
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("1:\(String(format: "%.1f", recipe.ratio))")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Rectangle().fill(.black.opacity(0.28)).frame(width: 1, height: 34)
                Text("\(recipe.totalWater) ml")
                    .font(.title.weight(.bold))
            }
            if recipe.generatedByAI, let description = recipe.aiDescription, !description.isEmpty {
                Text(description)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black.opacity(0.58))
                    .lineLimit(3)
            }
        }
        .foregroundStyle(.black.opacity(0.76))
        .padding(20)
        .background(
            LinearGradient(colors: [StudioTheme.accent, Color(red: 0.52, green: 0.70, blue: 0.71)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.top, 8)
    }

    private func detailMetric(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(18)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(0.78), lineWidth: 2)
        }
    }

    private func detailPour(index: Int, pour: PourStep) -> some View {
        let expanded = expandedPourID == pour.id
        let percentage = recipe.totalWater > 0 ? Int((Double(pour.volume) / Double(recipe.totalWater) * 100).rounded()) : 0
        return Button {
            withAnimation(.snappy) { expandedPourID = expanded ? nil : pour.id }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.muted)
                        Text("\(percentage)%")
                            .font(.system(size: 43, weight: .light, design: .rounded))
                    }
                    .frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(pour.volume) ml · \(pour.temperature)°C")
                            .font(.headline.monospacedDigit())
                        Text("\(String(format: "%.1f", pour.flowRate)) ml/s · \(pour.pauseAfter)s rest")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                        HStack(spacing: 6) {
                            PourFeatureBadge(
                                title: patternTitle(pour.pattern),
                                icon: AnyView(PourPatternMark(pattern: pour.pattern, size: 20))
                            )
                            if pour.agitationBefore || pour.agitationAfter {
                                AgitationTimingMarks(
                                    before: pour.agitationBefore,
                                    after: pour.agitationAfter,
                                    size: 20
                                )
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(StudioTheme.accent)
                }
                .padding(18)
                if expanded {
                    Divider().overlay(.white.opacity(0.1))
                    VStack(spacing: 12) {
                        detailMetric("Volume", "\(pour.volume) ml", "drop.fill", StudioTheme.accent)
                        detailMetric("Temperature", "\(pour.temperature)°C", "thermometer.medium", .orange)
                        detailMetric("Flow rate", "\(String(format: "%.1f", pour.flowRate)) ml/s", "water.waves", .blue)
                        detailMetric("Pause after", "\(pour.pauseAfter) s", "pause.fill", .purple)
                        HStack(spacing: 8) {
                            PourFeatureBadge(
                                title: "\(patternTitle(pour.pattern)) pour",
                                icon: AnyView(PourPatternMark(pattern: pour.pattern, size: 24))
                            )
                            AgitationTimingMarks(
                                before: pour.agitationBefore,
                                after: pour.agitationAfter,
                                size: 22,
                                showInactive: true
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .buttonStyle(.plain)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(expanded ? StudioTheme.accent : .white.opacity(0.08), lineWidth: expanded ? 2 : 1)
        }
    }

    private func scenarioRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.black)
                .frame(width: 25, height: 25)
                .background(StudioTheme.accent, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.76))
        }
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
