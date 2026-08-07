import SwiftData
import SwiftUI
import XBloomCore

private struct HomeCupRecommendation {
    let stored: StoredRecipe
    let recipe: Recipe
    let beanName: String?
    let reason: String
}

struct HomeView: View {
    @Binding var selectedTab: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Query private var history: [StoredBrew]
    @State private var activeBeans = 0
    @State private var recipeCount = 0
    @State private var recentRecipeLookup: [UUID: StoredRecipe] = [:]
    @State private var nextCup: HomeCupRecommendation?

    init(selectedTab: Binding<Int>) {
        _selectedTab = selectedTab
        var descriptor = FetchDescriptor<StoredBrew>(
            sortBy: [SortDescriptor(\StoredBrew.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 3
        _history = Query(descriptor)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    LazyVStack(spacing: 24) {
                        welcomeHeader
                        machineHero
                        machineTools
                        nextCupCard
                        recentActivity
                        libraryOverview
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
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

    private var welcomeHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Good \(dayPart)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Ready for something\nexceptional?")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .tracking(-0.7)
            }
            Spacer()
            Image(systemName: "leaf.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.crema)
                .frame(width: 52, height: 52)
                .background(AppTheme.espresso, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: AppTheme.espresso.opacity(0.22), radius: 15, y: 7)
        }
        .padding(.top, 8)
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
                    color: machine.isConnected ? Color(red: 0.53, green: 0.93, blue: 0.68) : .white.opacity(0.78),
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
                    .foregroundStyle(AppTheme.crema)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(AppTheme.crema)
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
                        .foregroundStyle(AppTheme.espresso)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
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
                        .foregroundStyle(AppTheme.espresso)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            diagnosticMessage

            if let error = machine.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 1, green: 0.67, blue: 0.60))
            }
        }
        .padding(22)
        .foregroundStyle(.white)
        .background(AppTheme.heroGradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 180, height: 180)
                .offset(x: 55, y: -75)
                .allowsHitTesting(false)
        }
        .shadow(color: AppTheme.espresso.opacity(0.22), radius: 24, y: 12)
    }

    /// Direct access to the three machine subsystems, each on its own screen.
    private var machineTools: some View {
        VStack(spacing: 14) {
            AppSectionHeader(
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
                    tint: AppTheme.sage
                ) { ScaleView() }

                machineToolCard(
                    title: "Brewer",
                    detail: "Single pour",
                    icon: "drop.fill",
                    tint: AppTheme.coffee
                ) { ManualPourView() }

                machineToolCard(
                    title: "Grinder",
                    detail: "Size & speed",
                    icon: "circle.grid.cross.fill",
                    tint: AppTheme.crema
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
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(tint.opacity(machine.isConnected ? 0.45 : 0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!machine.isConnected)
        .opacity(machine.isConnected ? 1 : 0.55)
    }

    private var libraryOverview: some View {
        VStack(spacing: 14) {
            AppSectionHeader(title: "Your coffee", subtitle: "Everything stays on this iPhone")
            HStack(spacing: 12) {
                libraryButton(title: "Beans", value: activeBeans, icon: "leaf.fill", tint: AppTheme.sage, tab: 2)
                libraryButton(title: "Recipes", value: recipeCount, icon: "list.bullet.rectangle.fill", tint: AppTheme.crema, tab: 1)
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
        recentRecipeLookup = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })

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
    }

    @ViewBuilder
    private var nextCupCard: some View {
        if let nextCup {
            VStack(spacing: 12) {
                AppSectionHeader(title: "Your next cup", subtitle: "Chosen locally from your coffee memory")
                NavigationLink {
                    RecipeDetailView(stored: nextCup.stored, recipe: nextCup.recipe)
                } label: {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack(alignment: .top, spacing: 13) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
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
                                    .foregroundStyle(nextCup.recipe.brewStyle == .iced ? .cyan : AppTheme.crema)
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
                        .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(17)
                    .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(StudioTheme.accent.opacity(0.28), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentActivity: some View {
        VStack(spacing: 14) {
            AppSectionHeader(title: "Coffee memory", subtitle: "Your latest cups, ready to revisit")
            if history.isEmpty {
                HStack(spacing: 15) {
                    IconBadge(systemImage: "clock.arrow.circlepath", tint: .secondary, size: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No brews yet").font(.headline)
                        Text("Your first completed brew will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .appCard()
            } else {
                ForEach(history) { brew in
                    VStack(spacing: 12) {
                        NavigationLink {
                            BrewHistoryDetailView(brew: brew)
                        } label: {
                            HStack(spacing: 13) {
                                IconBadge(
                                    systemImage: brew.wasSimulated == true ? "play.rectangle.fill" : "waveform.path.ecg",
                                    tint: brew.wasSimulated == true ? .cyan : AppTheme.coffee,
                                    size: 46
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(brew.recipeName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(brew.completedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(StudioTheme.muted)
                                }
                                Spacer()
                                if let rating = brew.rating {
                                    Label("\(rating)", systemImage: "star.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AppTheme.crema)
                                } else {
                                    Text("UNRATED")
                                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                                        .tracking(0.6)
                                        .foregroundStyle(.orange)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 9) {
                            if let stored = recipeForBrew(brew), let recipe = stored.recipe {
                                NavigationLink {
                                    RecipeDetailView(stored: stored, recipe: recipe)
                                } label: {
                                    Label("Brew again", systemImage: "arrow.clockwise")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .foregroundStyle(.black)
                                        .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }

                            if brew.rating == nil {
                                NavigationLink {
                                    BrewHistoryDetailView(brew: brew)
                                } label: {
                                    Label("Rate cup", systemImage: "star")
                                        .font(.caption.weight(.bold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14)
                    .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.07), lineWidth: 1)
                    }
                }
            }

            NavigationLink {
                HistoryView()
            } label: {
                Text("View full brew history")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func recipeForBrew(_ brew: StoredBrew) -> StoredRecipe? {
        guard let id = brew.recipeID ?? brew.entry?.recipeID else { return nil }
        return recentRecipeLookup[id]
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
            .appCard()
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
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .foregroundStyle(AppTheme.crema)
        case .passed:
            Label("Machine responded — command channel verified.", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.53, green: 0.93, blue: 0.68))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color(red: 1, green: 0.67, blue: 0.60))
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
