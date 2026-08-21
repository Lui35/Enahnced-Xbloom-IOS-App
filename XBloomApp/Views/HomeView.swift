import SwiftData
import SwiftUI
import XBloomCore

private struct HomeCupRecommendation {
    let stored: StoredRecipe
    let recipe: Recipe
    let beanName: String?
    let reason: String
}

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
    @State private var nextCup: HomeCupRecommendation?
    @State private var lastCup: HomeLastCup?

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 24) {
                        welcomeHeader
                        machineHero
                        machineTools
                        nextCupCard
                        sinceLastCup
                        libraryOverview
                    }
                    .padding(.horizontal, StudioTheme.Space.margin)
                    .padding(.top, 6)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Good \(dayPart)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                MachineToolbar()
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
        }
    }

    /// The greeting is the screen's title, so it now sits in the navigation bar
    /// where iOS puts titles. It used to be four lines of 34pt display type plus
    /// a decorative leaf tile, which pushed the one thing this screen exists to
    /// show — whether the machine is reachable — below the fold.
    private var welcomeHeader: some View {
        Text("Ready for something exceptional?")
            .font(.subheadline)
            .foregroundStyle(StudioTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var machineHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(machine.machineName)
                        .font(.title2.weight(.bold))
                    Text(machineSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
                StatusPill(
                    title: machine.connectionState.rawValue.capitalized,
                    color: machine.isConnected ? StudioTheme.mint : .white.opacity(0.78),
                    systemImage: machine.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
                )
            }

            if machine.isConnected {
                HStack(spacing: 10) {
                    heroMetric("Weight", machine.telemetry.weight, "g")
                    heroMetric("Water", machine.telemetry.waterVolume, "ml")
                    heroMetric("Temp", machine.telemetry.temperature, "°")
                }
                Text(machine.telemetry.state.rawValue.capitalized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.crema)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(StudioTheme.crema)
                    Text("Keep your phone near the machine. Connection and brewing happen directly over Bluetooth.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if machine.isConnected {
                HStack(spacing: 10) {
                    Button {
                        Task { await machine.testConnection() }
                    } label: {
                        Label(
                            machine.diagnosticState == .testing ? "Testing…" : "Test machine",
                            systemImage: "wave.3.right"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(StudioTheme.background)
                        .background(
                            StudioTheme.accent,
                            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
                        )
                    }
                    .disabled(machine.diagnosticState == .testing)
                    .buttonStyle(.plain)

                    Button {
                        machine.disconnect()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 48, height: 48)
                            .foregroundStyle(.white)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    machine.connect()
                } label: {
                    Label("Connect xBloom", systemImage: "bolt.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(StudioTheme.background)
                        .background(
                            StudioTheme.accent,
                            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }

            diagnosticMessage

            if let error = machine.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.danger)
            }
        }
        .padding(22)
        .foregroundStyle(.white)
        .background(
            StudioTheme.heroGradient,
            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 180, height: 180)
                .offset(x: 55, y: -75)
                .allowsHitTesting(false)
        }
        .shadow(color: StudioTheme.background.opacity(0.22), radius: 24, y: 12)
    }

    /// Direct access to the three machine subsystems, each on its own screen.
    private var machineTools: some View {
        VStack(spacing: 14) {
            StudioSectionTitle(
                title: "Machine tools",
                subtitle: machine.isConnected
                    ? "Drive the scale, brewer, and grinder on their own"
                    : "Connect the machine to use these"
            )
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
                    .stroke(tint.opacity(machine.isConnected ? 0.45 : 0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!machine.isConnected)
        .opacity(machine.isConnected ? 1 : 0.55)
    }

    private var libraryOverview: some View {
        VStack(spacing: 14) {
            StudioSectionTitle(title: "Your coffee", subtitle: "Everything stays on this iPhone")
            HStack(spacing: 12) {
                libraryButton(title: "Beans", value: activeBeans, icon: "leaf.fill", tint: StudioTheme.mint, tab: 2)
                libraryButton(title: "Recipes", value: recipeCount, icon: "list.bullet.rectangle.fill", tint: StudioTheme.crema, tab: 1)
            }
            Button {
                selectedTab = 1
            } label: {
                Label("Choose a recipe & brew", systemImage: "cup.and.saucer.fill")
            }
            .buttonStyle(PrimaryActionButtonStyle())
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
        nextCup = makeNextCup(
            recipes: recipes,
            beans: beanProfiles,
            history: recentHistory
        )
        lastCup = makeLastCup(
            recipes: Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) }),
            beans: beanProfiles,
            history: recentHistory
        )
    }

    @ViewBuilder
    private var nextCupCard: some View {
        if let nextCup {
            VStack(spacing: 12) {
                StudioSectionTitle(title: "Your next cup", subtitle: "Chosen locally from your coffee memory")
                NavigationLink {
                    RecipeDetailView(stored: nextCup.stored, recipe: nextCup.recipe)
                } label: {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .top, spacing: 13) {
                            ZStack {
                                RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [StudioTheme.accent, StudioTheme.mint],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                Image(systemName: "cup.and.heat.waves.fill")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.black.opacity(0.72))
                            }
                            .frame(width: 54, height: 54)

                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(nextCup.recipe.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if nextCup.recipe.generatedByAI {
                                        Text("AI")
                                            .font(.caption2.weight(.heavy))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(StudioTheme.accent, in: Capsule())
                                    }
                                }
                                Text(nextCup.beanName ?? [nextCup.recipe.roaster, nextCup.recipe.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline)
                                    .foregroundStyle(StudioTheme.muted)
                                    .lineLimit(1)
                                Text("\(nextCup.recipe.brewStyle == .iced ? "Iced" : "Hot") · \(String(format: "%.1f", nextCup.recipe.dose)) g · 1:\(String(format: "%.1f", nextCup.recipe.ratio))")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(nextCup.recipe.brewStyle == .iced ? StudioTheme.iced : StudioTheme.crema)
                            }
                            Spacer(minLength: 0)
                        }

                        Text(nextCup.reason)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Label("Review & brew", systemImage: "play.fill")
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
                    }
                    .padding(17)
                    .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                            .stroke(StudioTheme.accent.opacity(0.28), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
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
                        Label("Brew it again", systemImage: "arrow.clockwise")
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

    private func makeNextCup(
        recipes: [StoredRecipe],
        beans: [UUID: BeanProfile],
        history: [StoredBrew]
    ) -> HomeCupRecommendation? {
        let lastRecipeID = history.first?.recipeID ?? history.first?.entry?.recipeID
        let ratings = Dictionary(grouping: history.filter { $0.rating != nil }) { brew in
            brew.recipeID ?? brew.entry?.recipeID
        }

        var best: (score: Double, value: HomeCupRecommendation)?
        for stored in recipes {
            guard let recipe = stored.recipe else { continue }
            let bean = recipe.beanID.flatMap { beans[$0] }
            if let bean, bean.remainingWeightGrams < recipe.dose { continue }

            let recipeRatings = ratings[recipe.id] ?? []
            let averageRating = recipeRatings.isEmpty
                ? nil
                : Double(recipeRatings.compactMap(\.rating).reduce(0, +)) / Double(recipeRatings.count)
            let roastAge = bean?.roastDate.map {
                max(0, Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0)
            }

            var score = 0.0
            if bean != nil { score += 24 }
            if recipe.id != lastRecipeID { score += 9 }
            if let averageRating { score += averageRating * 7 }
            if let roastAge { score += Double(min(24, roastAge)) }
            if recipe.generatedByAI { score += 2 }

            let reason: String
            if let bean, let roastAge, roastAge >= 12 {
                let doses = Int(floor(bean.remainingWeightGrams / max(1, recipe.dose)))
                reason = "Use \(bean.name) while it is still expressive—roasted \(roastAge) days ago with about \(doses) doses remaining."
            } else if let averageRating, averageRating >= 4 {
                reason = "A proven favorite from your own history, averaging \(String(format: "%.1f", averageRating)) out of 5."
            } else if recipe.id != lastRecipeID {
                reason = "A change of pace from your last cup, selected from beans and recipes already on this iPhone."
            } else {
                reason = "A dependable next cup based on what is currently available in your local coffee library."
            }

            let recommendation = HomeCupRecommendation(
                stored: stored,
                recipe: recipe,
                beanName: bean?.name,
                reason: reason
            )
            if best == nil || score > best!.score {
                best = (score, recommendation)
            }
        }
        return best?.value
    }

    private func libraryButton(title: String, value: Int, icon: String, tint: Color, tab: Int) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    IconBadge(systemImage: icon, tint: tint)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                Text("\(value)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioCard()
        }
        .buttonStyle(.plain)
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

    private var machineSubtitle: String {
        switch machine.connectionState {
        case .connected: "Live telemetry is ready"
        case .subscribing: "Opening the machine command channel…"
        case .connecting: "Pairing securely over Bluetooth…"
        case .scanning: "Searching for your machine…"
        case .unavailable: "Bluetooth is currently unavailable"
        case .disconnected: "Your personal coffee station"
        }
    }

    @ViewBuilder
    private var diagnosticMessage: some View {
        switch machine.diagnosticState {
        case .idle:
            if machine.isConnected {
                Label("Test briefly vibrates the scale tray and waits for a machine response.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
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

    private var dayPart: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "morning"
        case 12..<18: "afternoon"
        default: "evening"
        }
    }
}
