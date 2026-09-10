import Charts
import Observation
import SwiftData
import SwiftUI
import XBloomCore

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
