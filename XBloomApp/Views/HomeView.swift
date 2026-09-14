import SwiftData
import SwiftUI
import XBloomCore

/// What is different about a recipe now compared with the last time it was
/// actually brewed. History lists the cups; only Home can say what has moved
/// since.
private struct HomeLastCup {
    let stored: StoredRecipe
    let recipe: Recipe
    let brewedAt: Date
    let changes: [String]
}

struct HomeView: View {
    @Binding var selectedTab: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @State private var activeBeans = 0
    @State private var recipeCount = 0
    @State private var lastCup: HomeLastCup?
    @State private var favoriteRecipes: [StoredRecipe] = []
    @State private var latestBrew: BrewHistoryEntry?
    @State private var repeatingBrew: BrewHistoryEntry?

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 24) {
                        machineHero
                        machineTools
                        brewingSection
                        if !favoriteRecipes.isEmpty { favoritesSection }
                        libraryOverview
                        if lastCup != nil {
                            DisclosureGroup("Since your last brew") { sinceLastCup.padding(.top, 12) }
                                .font(.subheadline.weight(.semibold))
                                .studioCard()
                        }
                        ConnectionAndSyncStatus(showsMachineStatus: false)
                    }
                    .padding(.horizontal, StudioTheme.Space.margin)
                    .padding(.top, 6)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("xBloom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .onAppear { refreshDashboard() }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
                guard let context = notification.object as? ModelContext, context === modelContext else { return }
                refreshDashboard()
            }
            .sheet(item: $repeatingBrew) { RepeatBrewSheet(entry: $0) }
        }
    }



    private var isConnecting: Bool {
        [.scanning, .connecting, .subscribing].contains(machine.connectionState)
    }

    private var machineHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(systemImage: "cup.and.saucer.fill", tint: StudioTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(machine.machineName).font(.headline)
                    Label(machine.isConnected ? "Connected" : isConnecting ? "Connecting…" : "Not connected",
                          systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(machine.isConnected ? StudioTheme.mint : StudioTheme.muted)
                }
                Spacer(minLength: 0)
                if machine.isConnected {
                    Menu {
                        Button("Test connection (moves tray)", systemImage: "wave.3.right") {
                            Task { await machine.testConnection() }
                        }.disabled(machine.diagnosticState == .testing)
                        Button("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash") { machine.disconnect() }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }.accessibilityLabel("Machine actions")
                } else {
                    Button(isConnecting ? "Connecting…" : "Connect") { machine.connect() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .disabled(isConnecting)
                }
            }
            if machine.isConnected {
                HStack(spacing: 10) {
                    heroMetric("Weight", machine.telemetry.weight, "g")
                    heroMetric("Water", machine.telemetry.waterVolume, "ml")
                    heroMetric("Temp", machine.telemetry.temperature, "°")
                }
                Text(machine.telemetry.state.rawValue.capitalized)
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            } else {
                Text("Keep the machine awake and your phone nearby.")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
            diagnosticMessage
            if let error = machine.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(StudioTheme.danger)
            }
        }.studioCard()
    }


    /// Direct access to the three machine subsystems, each on its own screen.
    private var machineTools: some View {
        VStack(spacing: 14) {

            HStack(spacing: 12) {
                machineToolCard(
                    title: "Scale",
                    detail: machine.isConnected
                        ? String(format: "%.1f g", machine.telemetry.weight ?? 0)
                        : "Weigh & tare",
                    icon: "scalemass.fill",
                    tint: StudioTheme.mint
                ) { ScaleView() }

                machineToolCard(
                    title: "Brewer",
                    detail: "Single pour",
                    icon: "drop.fill",
                    tint: StudioTheme.accent
                ) { ManualPourView() }

                machineToolCard(
                    title: "Grinder",
                    detail: "Size & speed",
                    icon: "circle.grid.cross.fill",
                    tint: StudioTheme.crema
                ) { GrinderView() }
            }
        }
    }

    private func machineToolCard<Destination: View>(
        title: String,
        detail: String,
        icon: String,
        tint: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            VStack(alignment: .leading, spacing: 10) {
                IconBadge(systemImage: icon, tint: tint, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                    .strokeBorder(StudioTheme.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!machine.isConnected)
    }

    private var libraryOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioSectionTitle(title: "Your library")
            HStack(spacing: 12) {
                libraryButton(title: "Beans", value: activeBeans, icon: "leaf", tint: StudioTheme.crema, tab: 2)
                libraryButton(title: "Recipes", value: recipeCount, icon: "list.bullet.rectangle", tint: StudioTheme.accent, tab: 1)
            }
        }
    }

    private var brewingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSectionTitle(title: "Brew coffee")
            Button { selectedTab = 1 } label: {
                Label("Choose a recipe", systemImage: "cup.and.saucer.fill")
            }.buttonStyle(PrimaryActionButtonStyle())
            repeatLastBrew
        }
    }


    private func refreshDashboard() {
        let activeDescriptor = FetchDescriptor<StoredBean>(
            predicate: #Predicate { !$0.archived }
        )
        activeBeans = (try? modelContext.fetchCount(activeDescriptor)) ?? activeBeans
        recipeCount = (try? modelContext.fetchCount(FetchDescriptor<StoredRecipe>())) ?? recipeCount

        let recipes = (try? modelContext.fetch(
            FetchDescriptor<StoredRecipe>(
                sortBy: [SortDescriptor(\StoredRecipe.updatedAt, order: .reverse)]
            )
        )) ?? []

        favoriteRecipes = recipes.filter { $0.recipe?.isFavorite == true }
        let beans = (try? modelContext.fetch(activeDescriptor)) ?? []
        let beanProfiles = Dictionary(
            uniqueKeysWithValues: beans.compactMap { stored in
                stored.profile.map { (stored.id, $0) }
            }
        )

        var historyDescriptor = FetchDescriptor<StoredBrew>(
            sortBy: [SortDescriptor(\StoredBrew.completedAt, order: .reverse)]
        )
        historyDescriptor.fetchLimit = 60
        let recentHistory = (try? modelContext.fetch(historyDescriptor)) ?? []
        latestBrew = recentHistory.first(where: { $0.wasSimulated != true && $0.entry?.recipeSnapshot != nil })?.entry
        lastCup = makeLastCup(
            recipes: Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) }),
            beans: beanProfiles,
            history: recentHistory
        )
    }



    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioSectionTitle(title: "Favorites", icon: "heart.fill")
            if favoriteRecipes.isEmpty {
                Text("Tap the heart on a recipe to keep it close. Your favorites sync with your library.")
                    .font(.subheadline).foregroundStyle(StudioTheme.muted)
            } else {
                ForEach(Array(favoriteRecipes.prefix(4))) { stored in
                    if let recipe = stored.recipe {
                        HStack {
                            NavigationLink {
                                RecipeDetailView(stored: stored, recipe: recipe)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recipe.name).font(.headline)
                                    Text(String(format: "%.1f g · %d ml · %@", recipe.dose, recipe.totalWater,
                                                recipe.brewStyle == .iced ? "Iced" : "Hot"))
                                        .font(.caption).foregroundStyle(StudioTheme.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            FavoriteRecipeButton(stored: stored).labelStyle(.iconOnly)
                        }.padding(15).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    @ViewBuilder private var repeatLastBrew: some View {
        if let latestBrew {
            Button { repeatingBrew = latestBrew } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise").font(.title3).foregroundStyle(StudioTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Repeat your last brew").font(.caption).foregroundStyle(StudioTheme.muted)
                        Text(latestBrew.recipeName).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(latestBrew.completedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(StudioTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
            }.buttonStyle(.plain)
            .accessibilityHint("Review the original dose and pours before starting")
        }
    }


    /// The one thing History cannot show: what moved since the last time this
    /// recipe was brewed — an edited dose, a bag running out, beans getting
    /// older. The list of past cups lives in the History tab.
    @ViewBuilder
    private var sinceLastCup: some View {
        if let lastCup {
            VStack(spacing: 14) {
                StudioSectionTitle(
                    title: "Since your last cup",
                    subtitle: "\(lastCup.recipe.name) · \(lastCup.brewedAt.formatted(.relative(presentation: .named)))"
                )
                VStack(alignment: .leading, spacing: 12) {
                    if lastCup.changes.isEmpty {
                        Label("Nothing has moved — same recipe, same bag.", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(StudioTheme.mint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(lastCup.changes, id: \.self) { change in
                            Label(change, systemImage: "arrow.turn.down.right")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    NavigationLink {
                        RecipeDetailView(stored: lastCup.stored, recipe: lastCup.recipe)
                    } label: {
                        Label("Review current recipe", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundStyle(.black)
                            .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioCard()
            }
        }
    }

    private func makeLastCup(
        recipes: [UUID: StoredRecipe],
        beans: [UUID: BeanProfile],
        history: [StoredBrew]
    ) -> HomeLastCup? {
        guard let brew = history.first(where: { ($0.recipeID ?? $0.entry?.recipeID) != nil }),
              let id = brew.recipeID ?? brew.entry?.recipeID,
              let stored = recipes[id],
              let recipe = stored.recipe
        else { return nil }

        var changes: [String] = []
        if let then = brew.entry?.recipeSnapshot {
            if abs(then.dose - recipe.dose) >= 0.1 {
                changes.append(String(format: "Dose is %.1f g now, was %.1f g", recipe.dose, then.dose))
            }
            if then.grindSize != recipe.grindSize {
                changes.append("Grind is \(recipe.grindSize) now, was \(then.grindSize)")
            }
            if then.totalWater != recipe.totalWater {
                changes.append("Water is \(recipe.totalWater) ml now, was \(then.totalWater) ml")
            }
        }
        if let bean = recipe.beanID.flatMap({ beans[$0] }) {
            if bean.remainingWeightGrams < recipe.dose {
                changes.append(
                    String(
                        format: "%@ has %.0f g left — short of the %.1f g this wants",
                        bean.name,
                        bean.remainingWeightGrams,
                        recipe.dose
                    )
                )
            } else {
                let doses = Int(floor(bean.remainingWeightGrams / max(1, recipe.dose)))
                changes.append(
                    String(
                        format: "%@ has %.0f g left — about %d more cups",
                        bean.name,
                        bean.remainingWeightGrams,
                        doses
                    )
                )
            }
            if let roastDate = bean.roastDate {
                let days = max(0, Calendar.current.dateComponents([.day], from: roastDate, to: Date()).day ?? 0)
                changes.append("Those beans are \(days) days off roast now")
            }
        }
        if brew.rating == nil {
            changes.append("You never rated that cup")
        }

        return HomeLastCup(
            stored: stored,
            recipe: recipe,
            brewedAt: brew.completedAt,
            // ponytail: a fixed cap keeps the card short; rank them if it ever
            // matters which four survive.
            changes: Array(changes.prefix(4))
        )
    }



    private func libraryButton(title: String, value: Int, icon: String, tint: Color, tab: Int) -> some View {
        Button { selectedTab = tab } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.subheadline).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("\(value)").font(.headline.monospacedDigit()).foregroundStyle(StudioTheme.muted)
            }.frame(minHeight: 32).studioCard(padding: 14)
        }.buttonStyle(.plain)
    }

    private func heroMetric(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(value.map { "\(String(format: "%.1f", $0))\(unit)" } ?? "—")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
    }



    @ViewBuilder
    private var diagnosticMessage: some View {
        switch machine.diagnosticState {
        case .idle: EmptyView()
        case .testing:
            Label("Sending a safe movement test…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.crema)
        case .passed:
            Label("Machine responded — command channel verified.", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.mint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(StudioTheme.danger)
        }
    }

}
