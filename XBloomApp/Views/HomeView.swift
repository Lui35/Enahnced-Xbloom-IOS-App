import SwiftData
import SwiftUI
import XBloomCore

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selectedTab: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @State private var favoriteRecipes: [StoredRecipe] = []
    @State private var latestBrew: BrewHistoryEntry?
    @State private var repeatingBrew: BrewHistoryEntry?
    @State private var showsFavorites = false
    @State private var showsWaterTankDetails = false

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ViewThatFits(in: .vertical) {
                    dashboard(compact: false)
                    dashboard(compact: true)
                    dashboard(compact: true, minimal: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, StudioTheme.Space.margin)
                .padding(.top, 12)
                // Keep the same dashboard space whether the warning is present or not.
                .padding(.bottom, 74)
                .overlay(alignment: .bottom) {
                    if machine.waterTankWarning.needsCheck {
                        waterTankStatus
                            .padding(.horizontal, StudioTheme.Space.margin)
                            .padding(.bottom, 18)
                    }
                }

            }
            .navigationTitle("xBloom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                MachineToolbar()
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(StudioTheme.accent)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .onAppear { refreshDashboard() }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
                guard let context = notification.object as? ModelContext, context === modelContext else { return }
                refreshDashboard()
            }
            .sheet(isPresented: $showsWaterTankDetails) {
                WaterTankCheckSheet(onCancel: { showsWaterTankDetails = false })
            }
            .sheet(item: $repeatingBrew) { RepeatBrewSheet(entry: $0) }
            .sheet(isPresented: $showsFavorites) {
                NavigationStack {
                    ScrollView { favoritesSection.padding(StudioTheme.Space.margin) }
                        .background(StudioTheme.background)
                        .navigationTitle("Favorites")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsFavorites = false }.frame(minHeight: 44)
                            }
                        }
                }
                .tint(StudioTheme.accent)
                .preferredColorScheme(.dark)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }

        }
    }

    private var waterTankStatus: some View {
        Button { showsWaterTankDetails = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "drop.triangle.fill").accessibilityHidden(true)
                Text(machine.isConnected ? "Check water tank" : "Low water reported")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "info.circle").accessibilityHidden(true)
            }
            .foregroundStyle(StudioTheme.warning)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(StudioTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHint("Read the low-water report and how to check the tank")
        .accessibilityIdentifier("home.waterTankWarning")
    }

    /// Two intrinsic-height layouts let Home fit its safe area without scrolling.
    private func dashboard(compact: Bool, minimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            machineTools(compact: compact, minimal: minimal)
            brewingSection(compact: compact, minimal: minimal)
            if !favoriteRecipes.isEmpty {
                Button { showsFavorites = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "heart").accessibilityHidden(true)
                        Text("Favorites")
                        Spacer()
                        Text("\(favoriteRecipes.count)").monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
                    .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.favorites")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Hardware actions remain gated by the actual Bluetooth connection.
    private func machineTools(compact: Bool, minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                StudioSectionTitle(title: minimal ? "Quick tools" : "At your fingertips")
                Spacer()
                if !machine.isConnected {
                    Image(systemName: "lock")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                        .accessibilityHidden(true)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: compact && dynamicTypeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
                machineToolCard(title: "Scale", detail: machine.isConnected
                                ? String(format: "%.1f g", machine.telemetry.weight ?? 0) : "Weigh & tare",
                                icon: StudioSymbol.weight, tint: StudioTheme.mint, compact: compact) { ScaleView() }
                machineToolCard(title: "Brewer", detail: "Single pour", icon: "drop", tint: StudioTheme.accent, compact: compact) { ManualPourView() }
                machineToolCard(title: "Grinder", detail: "Size & speed", icon: "circle.grid.cross", tint: StudioTheme.crema, compact: compact) { GrinderView() }
            }
            if !machine.isConnected && !compact {
                Text("Connect your machine to unlock live tools.")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
        }
    }

    private func machineToolCard<Destination: View>(
        title: String, detail: String, icon: String, tint: Color, compact: Bool,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            Group {
                if compact {
                    HStack(spacing: 10) {
                        Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
                        Text(title).foregroundStyle(.white).lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 10)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: icon).font(.title3).foregroundStyle(tint)
                                .accessibilityHidden(true)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StudioTheme.muted).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text(detail).font(.caption).foregroundStyle(StudioTheme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                    .padding(14)
                }
            }
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.line) }
            .opacity(machine.isConnected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.tool.\(title.lowercased())")
        .disabled(!machine.isConnected)
    }

    private func brewingSection(compact: Bool, minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                if compact && !minimal {
                    Text("Your next cup")
                        .font(.headline).foregroundStyle(.white)
                } else if !compact {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MAKE IT YOURS")
                                .font(.caption2.weight(.semibold)).tracking(2)
                                .foregroundStyle(StudioTheme.accent)
                            Text("A good cup.\nYour way.")
                                .font(.system(.title, design: .serif).weight(.regular))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Find a recipe. Fine-tune every pour.")
                                .font(.subheadline).foregroundStyle(StudioTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if !dynamicTypeSize.isAccessibilitySize {
                            HomeBrewIllustration()
                                .frame(width: 94, height: 120)
                                .accessibilityHidden(true)
                        }
                    }
                }
                Button { selectedTab = 1 } label: {
                    HStack {
                        Text("Choose a recipe")
                        Spacer()
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }.padding(.horizontal, 18)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .accessibilityIdentifier("home.chooseRecipe")
            }
            .padding(compact ? 16 : 20)
            .background {
                RoundedRectangle(cornerRadius: 26)
                    .fill(LinearGradient(colors: [StudioTheme.accent.opacity(0.13), StudioTheme.panel], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(StudioTheme.accent.opacity(0.18)) }
            if minimal, let latestBrew {
                Button { repeatingBrew = latestBrew } label: {
                    Label("Repeat last brew", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Review the original dose and pours before starting")
            } else {
                repeatLastBrew(compact: compact)
            }
        }
    }

    private func refreshDashboard() {
        let recipes = (try? modelContext.fetch(
            FetchDescriptor<StoredRecipe>(
                sortBy: [SortDescriptor(\StoredRecipe.updatedAt, order: .reverse)]
            )
        )) ?? []

        favoriteRecipes = recipes.filter { $0.recipe?.isFavorite == true }
        var historyDescriptor = FetchDescriptor<StoredBrew>(
            sortBy: [SortDescriptor(\StoredBrew.completedAt, order: .reverse)]
        )
        historyDescriptor.fetchLimit = 60
        let recentHistory = (try? modelContext.fetch(historyDescriptor)) ?? []
        latestBrew = recentHistory.first(where: { $0.wasSimulated != true && $0.entry?.recipeSnapshot != nil })?.entry

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

    @ViewBuilder private func repeatLastBrew(compact: Bool) -> some View {
        if let latestBrew {
            Button { repeatingBrew = latestBrew } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise").font(.title3).foregroundStyle(StudioTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Repeat your last brew").font(.caption).foregroundStyle(StudioTheme.muted)
                        Text(latestBrew.recipeName).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        if !compact {
                            Text(latestBrew.completedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(StudioTheme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(StudioTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
            }.buttonStyle(.plain)
            .accessibilityHint("Review the original dose and pours before starting")
        }
    }


}

/// A quiet line drawing keeps the primary action prominent without a raster hero.
private struct HomeBrewIllustration: View {
    var body: some View {
        ZStack {
            Circle().fill(StudioTheme.accent.opacity(0.06)).frame(width: 112, height: 112)
            Circle().stroke(StudioTheme.accent.opacity(0.14), lineWidth: 1).frame(width: 94, height: 94)
            VStack(spacing: 6) {
                HStack(spacing: 9) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(StudioTheme.accent.opacity(0.45)).frame(width: 1.5, height: 15)
                    }
                }
                Image(systemName: "cup.and.saucer")
                    .font(.system(size: 49, weight: .ultraLight))
                    .foregroundStyle(StudioTheme.accent)
                HStack(spacing: 4) {
                    Circle().fill(StudioTheme.accent).frame(width: 3, height: 3)
                    Capsule().fill(StudioTheme.accent.opacity(0.25)).frame(width: 22, height: 2)
                    Circle().fill(StudioTheme.accent).frame(width: 3, height: 3)
                }
            }
        }
    }
}
