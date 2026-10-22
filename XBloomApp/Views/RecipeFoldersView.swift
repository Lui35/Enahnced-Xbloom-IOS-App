import SwiftData
import SwiftUI
import XBloomCore

/// Both layouts use the same saved recipes, grouped by their linked bean.
struct RecipeFoldersView: View {
    let recipes: [StoredRecipe]
    let filter: RecipeLibraryFilter
    let searchText: String
    @Query(sort: \StoredBean.name) private var beans: [StoredBean]
    @AppStorage("recipes.brewTargetDays") private var targetDays = 30

    private var profiles: [BeanProfile] { beans.compactMap(\.profile) }
    private var matchingRecipes: [StoredRecipe] {
        recipes.filter { stored in
            guard let recipe = stored.recipe, filter.includes(recipe) else { return false }
            let bean = beans.first { $0.id == recipe.beanID }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || recipe.matchesLibrarySearch(query)
                || bean?.name.localizedCaseInsensitiveContains(query) == true
                || bean?.roaster.localizedCaseInsensitiveContains(query) == true
        }
    }
    private var folders: [RecipeFolder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecipeFolders.make(beans: profiles, recipes: matchingRecipes.compactMap(\.recipe),
                                  includeEmptyBeans: filter == .all)
            .filter { folder in
                guard !query.isEmpty, folder.recipeIDs.isEmpty else { return true }
                return beans.contains { RecipeFolderKey.bean($0.id) == folder.id
                    && ($0.name.localizedCaseInsensitiveContains(query) || $0.roaster.localizedCaseInsensitiveContains(query)) }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(folders) { folder in
                let bean = beans.first { .bean($0.id) == folder.id }
                NavigationLink {
                    RecipeFolderDetailView(folder: folder, initialFilter: filter, initialSearch: searchText)
                } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            Image(systemName: StudioSymbol.bean)
                                .foregroundStyle(StudioTheme.accent)
                                .font(.title2.weight(.semibold))
                                .frame(width: 46, height: 46)
                                .background(StudioTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(folder.title).font(.headline).foregroundStyle(.white)
                                Text(bean.map { $0.archived ? "Archived bag" : ($0.roaster.isEmpty ? "Your coffee beans" : $0.roaster) }
                                     ?? (folder.id == .unavailableBeans ? "Original bag no longer available" : "Recipes without a linked bean"))
                                    .font(.caption).foregroundStyle(StudioTheme.muted)
                            }
                            Spacer(minLength: 0)
                            Text("\(folder.recipeIDs.count)").font(.title3.monospacedDigit()).foregroundStyle(StudioTheme.accent)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(StudioTheme.muted)
                                .accessibilityHidden(true)
                        }
                        if let bean { BeanFolderStockView(bean: bean, targetDays: targetDays) }
                    }
                    .studioCard()
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Open \(folder.recipeIDs.count) recipes")
            }
            if folders.isEmpty {
                ContentUnavailableView("No matching folders", systemImage: StudioSymbol.bean,
                                       description: Text("Try another filter, add a bean, or create a recipe."))
                    .frame(minHeight: 220)
            }
        }
    }

}

private struct BeanFolderStockView: View {
    let bean: StoredBean
    let targetDays: Int
    private var stock: Double { bean.remainingWeightGrams.isFinite ? max(0, bean.remainingWeightGrams) : 0 }

    var body: some View {
        let window = BeanBrewWindow(roastDate: bean.profile?.roastDate, targetDays: targetDays)
        VStack(alignment: .leading, spacing: 9) {
            BagInventorySummary(remainingGrams: stock, totalGrams: bean.profile?.initialWeightGrams ?? 250)
            targetLabel(window).font(.caption).foregroundStyle(StudioTheme.muted)

        }
    }

    @ViewBuilder private func targetLabel(_ window: BeanBrewWindow) -> some View {
        if let remaining = window.daysRemaining {
            Label(remaining >= 0 ? "\(remaining) days to target" : "\(-remaining) days past target", systemImage: "calendar")
                .foregroundStyle(remaining >= 0 ? StudioTheme.muted : StudioTheme.warning)
        } else {
            Label(window.ageInDays == nil ? "Roast date not set" : "Check future roast date", systemImage: "calendar.badge.questionmark")
        }
    }
}

private struct RecipeFolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let folder: RecipeFolder
    @Query(sort: \StoredRecipe.updatedAt, order: .reverse) private var allRecipes: [StoredRecipe]
    @Query private var beans: [StoredBean]
    @State private var filter: RecipeLibraryFilter
    @State private var search: String
    @Environment(\.selectedTab) private var selectedTab
    @Environment(\.beanEditRequest) private var beanEditRequest
    @State private var designingBean: BeanProfile?
    @State private var draft: Recipe?
    @State private var showingRecipePicker = false
    @State private var linkError: String?

    init(folder: RecipeFolder, initialFilter: RecipeLibraryFilter, initialSearch: String) {
        self.folder = folder
        _filter = State(initialValue: initialFilter)
        _search = State(initialValue: initialSearch)
    }
    private var bean: StoredBean? { beans.first { .bean($0.id) == folder.id } }
    private var members: [StoredRecipe] {
        let ids = Set(beans.compactMap(\.profile).map(\.id))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let beanMatches = bean.map { $0.name.localizedCaseInsensitiveContains(query) || $0.roaster.localizedCaseInsensitiveContains(query) } ?? false
        return allRecipes.filter {
            guard let recipe = $0.recipe, RecipeFolderKey.key(for: recipe, beanIDs: ids) == folder.id,
                  filter.includes(recipe) else { return false }
            return query.isEmpty || beanMatches || recipe.matchesLibrarySearch(query)
        }
    }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let bean {
                        BeanLibraryHeader(name: bean.name, roaster: bean.roaster)
                        if !bean.archived, let profile = bean.profile {
                            BeanRecipeDesignButton { designingBean = profile }
                        }
                    }
                    TextField("Search this folder", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    Text("\(members.count) \(members.count == 1 ? "recipe" : "recipes")").font(.caption).foregroundStyle(StudioTheme.muted)
                    ForEach(members) { stored in
                        VStack(alignment: .leading, spacing: 6) {
                            RecipeLibraryCard(stored: stored)
                            if let bean, let dose = stored.recipe?.dose, dose.isFinite, dose > bean.remainingWeightGrams {
                                Label(String(format: "Not enough beans for %.0f g", dose), systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(StudioTheme.warning).padding(.horizontal, 8)
                            }
                        }
                    }
                    if members.isEmpty {
                        ContentUnavailableView("No recipes here yet", systemImage: "cup.and.saucer",
                                               description: Text("Try another search or add a recipe using the + button."))
                    }
                }.padding(.horizontal, 18).padding(.vertical, 12).padding(.bottom, 24)
            }
        }
        .navigationTitle(bean?.name ?? folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if let bean {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beanEditRequest?.wrappedValue = bean.id
                        selectedTab?.wrappedValue = 2
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(StudioTheme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Edit \(bean.name) in Beans")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Create manually", systemImage: "slider.horizontal.3") { createDraft() }
                    if let bean, !bean.archived {
                        Button("Add existing recipe", systemImage: "link") { showingRecipePicker = true }
                        if let profile = bean.profile {
                            Button("Create with AI", systemImage: "wand.and.sparkles") { designingBean = profile }
                        }
                    }
                } label: { Image(systemName: "plus").foregroundStyle(StudioTheme.accent).frame(width: 44, height: 44) }
                .accessibilityLabel("Add recipe to folder")
            }
        }
        .sheet(item: $draft) { recipe in
            RecipeEditorView(recipe: recipe) { saved in
                modelContext.insert(StoredRecipe(recipe: saved))
                do { try modelContext.save() } catch { linkError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showingRecipePicker) {
            NavigationStack {
                List {
                    Text("Select a recipe to move into this bean’s folder. Its brewing settings stay the same.")
                        .font(.footnote).foregroundStyle(StudioTheme.muted)
                    ForEach(allRecipes.filter { $0.recipe != nil && $0.recipe?.beanID != bean?.id }) { stored in
                        Button {
                            guard let bean, var recipe = stored.recipe else { return }
                            let original = recipe
                            recipe.beanID = bean.id
                            stored.update(with: recipe)
                            do { try modelContext.save(); showingRecipePicker = false }
                            catch { stored.update(with: original); linkError = error.localizedDescription }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stored.name)
                                Text(stored.recipe?.beanID == nil ? "General recipe" : "Move from its current bean folder")
                                    .font(.caption).foregroundStyle(StudioTheme.muted)
                            }.frame(minHeight: 44)
                        }
                    }
                }
                .navigationTitle("Add existing recipe")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingRecipePicker = false } } }
                .preferredColorScheme(.dark)
            }
        }
        .alert("Couldn’t save recipe", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK") { linkError = nil }
        } message: { Text(linkError ?? "") }
        .sheet(item: $designingBean) { AIRecipeDesignerView(bean: $0) }
    }

    private func createDraft() {
        let style: BrewStyle = folder.id == .generalIced ? .iced : .hot
        var recipe = RecipeLibrary.defaults.first { $0.brewStyle == style } ?? RecipeLibrary.defaults[0]
        recipe.id = UUID()
        recipe.name = ""
        recipe.beanID = bean?.id
        recipe.roaster = bean?.roaster ?? ""
        recipe.origin = bean?.profile?.country ?? ""
        recipe.generatedByAI = false
        recipe.aiDescription = nil
        recipe.parentRecipeID = nil
        recipe.sourceBrewID = nil
        recipe.isFavorite = nil
        recipe.pours = recipe.pours.map { step in var value = step; value.id = UUID(); return value }
        draft = recipe
    }
}

/// Identical recipe actions in the list and inside every folder.
struct RecipeLibraryCard: View {
    @Environment(\.modelContext) private var modelContext
    let stored: StoredRecipe
    var body: some View {
        if let recipe = stored.recipe {
            NavigationLink { RecipeDetailView(stored: stored, recipe: recipe) } label: {
                RecipeRow(recipe: recipe).padding(16)
            }
            .buttonStyle(.plain)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card))
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.Radius.card))
            .overlay { RoundedRectangle(cornerRadius: StudioTheme.Radius.card).stroke(StudioTheme.line) }
            .contextMenu {
                FavoriteRecipeButton(stored: stored)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    try? LocalLibrary.delete(recipe: stored, in: modelContext)
                }
            }
        }
    }
}
