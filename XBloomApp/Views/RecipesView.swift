import SwiftData
import SwiftUI
import XBloomCore

enum RecipeLibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    case hot = "Hot"
    case iced = "Iced"

    var id: String { rawValue }

    func includes(_ recipe: Recipe) -> Bool {
        switch self {
        case .all: true
        case .favorites: recipe.isFavorite == true
        case .hot: recipe.brewStyle == .hot
        case .iced: recipe.brewStyle == .iced
        }
    }
}

struct RecipeLibraryFilterPicker: View {
    @Binding var selection: RecipeLibraryFilter

    var body: some View {
        Picker("Recipe collection", selection: $selection) {
            ForEach(RecipeLibraryFilter.allCases) { filter in
                Text(filter.rawValue)
                .tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Show all recipes, favorites, hot recipes, or iced recipes")
    }
}

struct RecipesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RecipeGenerationCoordinator.self) private var generation
    @Query(sort: \StoredRecipe.updatedAt, order: .reverse) private var recipes: [StoredRecipe]
    @State private var path = NavigationPath()
    @State private var shownRequestID: UUID?
    @State private var draft: Recipe?
    @State private var isDesigningWithAI = false
    @State private var searchText = ""
    @State private var selectedFilter: RecipeLibraryFilter = .all

    /// Generations worth showing on the filter that is on screen.
    private var visiblePending: [RecipeGenerationCoordinator.Pending] {
        generation.pending.filter { item in
            switch selectedFilter {
            case .all: true
            case .favorites: false
            case .hot: item.style == .hot
            case .iced: item.style == .iced
            }
        }
    }

    private func revealRequestedJob() {
        guard let id = generation.libraryRequestID, id != shownRequestID else { return }
        shownRequestID = id
        path = NavigationPath()
        selectedFilter = .all
        searchText = ""
    }

    private var filteredRecipes: [StoredRecipe] {
        recipes.filter { stored in
            guard let recipe = stored.recipe, selectedFilter.includes(recipe) else { return false }
            return recipe.matchesLibrarySearch(searchText)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 14) {
                        // The navigation bar names the screen. It used to say
                        // "Recipes" while a second bold headline underneath said
                        // "Recipe library" — one screen, two names, two titles.
                        HStack(alignment: .firstTextBaseline) {
                            Text("Programs ready for your xBloom")
                                .font(.subheadline)
                                .foregroundStyle(StudioTheme.muted)
                            Spacer(minLength: 10)
                            StatusPill(
                                title: recipes.count == 1 ? "1 saved" : "\(recipes.count) saved",
                                color: StudioTheme.accent,
                                systemImage: "bookmark.fill"
                            )
                        }

                        recipeSearchField

                        RecipeLibraryFilterPicker(selection: $selectedFilter)
                            .padding(.bottom, 4)

                        // A request that failed after the designer was closed
                        // would otherwise just remove its card, which reads as
                        // "nothing happened" rather than "this did not work".
                        if let failure = generation.lastError {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(StudioTheme.warning)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("The recipe was not designed")
                                        .font(.subheadline.weight(.bold))
                                    Text(failure)
                                        .font(.caption)
                                        .foregroundStyle(StudioTheme.muted)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    generation.clearError()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(StudioTheme.muted)
                                        .frame(width: 30, height: 30)
                                        .background(StudioTheme.raised, in: Circle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                                    .stroke(StudioTheme.warning.opacity(0.4), lineWidth: 1.5)
                            }
                            .transition(.opacity)
                        }

                        // A recipe still being written, shown where it will
                        // land. The request belongs to the app rather than to
                        // the designer sheet, so this survives leaving it.
                        ForEach(visiblePending) { item in
                            AIGeneratingCard(
                                title: item.isEnhancement ? "Enhancing from feedback" : "Designing a recipe",
                                subtitle: "\(item.beanName) · \(item.style == .iced ? "Iced" : "Hot") · \(item.cups) cup\(item.cups == 1 ? "" : "s")",
                                icon: item.isEnhancement ? "star.bubble.fill" : "wand.and.sparkles",
                                tint: item.isEnhancement ? .purple : (item.style == .iced ? StudioTheme.iced : StudioTheme.accent)
                            ) {
                                generation.cancel(item.id)
                            }
                            .transition(.popIn)
                        }

                        if filteredRecipes.isEmpty, visiblePending.isEmpty {
                            ContentUnavailableView(
                                searchText.isEmpty ? (selectedFilter == .favorites ? "No favorites yet" : "No recipes in this collection") : "No recipes found",
                                systemImage: searchText.isEmpty ? "cup.and.saucer" : "magnifyingglass",
                                description: Text(
                                    searchText.isEmpty
                                        ? (selectedFilter == .favorites ? "Use the heart on a recipe to save it here." : "Create a recipe to add it to this collection.")
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
                                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                                .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                                        .stroke(.white.opacity(0.08), lineWidth: 1)
                                }
                                .transition(.popIn)
                                .contextMenu {
                                    FavoriteRecipeButton(stored: stored)
                                    // Historical brews retain their own snapshots and usage.
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        try? LocalLibrary.delete(recipe: stored, in: modelContext)
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
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                MachineToolbar()
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Create with AI", systemImage: "wand.and.sparkles") {
                            isDesigningWithAI = true
                        }
                        Button("Create manually", systemImage: "slider.horizontal.3") {
                            draft = Recipe(
                                name: "",
                                pours: [
                                    PourStep(volume: 50, temperature: 93, pauseAfter: 30),
                                    PourStep(volume: 120, temperature: 93, flowRate: 3.3),
                                    PourStep(volume: 118, temperature: 92, flowRate: 3.5),
                                ]
                            )
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            // The same designer the bean shelf opens, without a bean chosen
            // yet. One screen, two doors.
            .sheet(isPresented: $isDesigningWithAI) {
                AIRecipeDesignerView(bean: nil)
            }
            .sheet(item: $draft) { recipe in
                RecipeEditorView(recipe: recipe) { saved in
                    modelContext.insert(StoredRecipe(recipe: saved))
                    try? modelContext.save()
                }
            }
        }
        .id(generation.libraryRequestID)
        .preferredColorScheme(.dark)
        .onAppear { revealRequestedJob() }
        .onChange(of: generation.libraryRequestID) { _, _ in revealRequestedJob() }
        // The placeholder leaving and the real recipe arriving are one motion,
        // and a spring is what makes the arrival read as a pop.
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: generation.pending.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: recipes.count)
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
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
