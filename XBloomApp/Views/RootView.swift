import SwiftData
import SwiftUI

private struct SelectedTabKey: EnvironmentKey {
    static let defaultValue: Binding<Int>? = nil
}

private struct BeanEditRequestKey: EnvironmentKey {
    static let defaultValue: Binding<UUID?>? = nil
}

extension EnvironmentValues {
    var beanEditRequest: Binding<UUID?>? {
        get { self[BeanEditRequestKey.self] }
        set { self[BeanEditRequestKey.self] = newValue }
    }

    /// The tab a screen can send the user to.
    ///
    /// A sheet presented from deep inside one tab cannot reach `RootView`'s
    /// state any other way, so a button promising "Back to Recipes" could only
    /// ever `dismiss()` — which puts the user back on the tab the sheet came
    /// from, Beans included.
    var selectedTab: Binding<Int>? {
        get { self[SelectedTabKey.self] }
        set { self[SelectedTabKey.self] = newValue }
    }
}

struct RootView: View {
    var recipeImportCount = 0
    @Environment(\.modelContext) private var modelContext
    @Environment(BrewSessionCoordinator.self) private var brewSession
    @State private var selectedTab = 0
    @State private var beanEditRequest: UUID?
    @State private var seedError: String?
    @State private var isLaunching = true

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView(selectedTab: $selectedTab)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(0)
                RecipesView()
                    .tabItem { Label("Recipes", systemImage: "list.bullet.rectangle") }
                    .tag(1)
                BeansView()
                    .tabItem { Label("Beans", systemImage: StudioSymbol.bean) }
                    .tag(2)
                NavigationStack {
                    HistoryView()
                }
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                    .tag(3)
            }

            if isLaunching {
                StartupLoadingView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .environment(\.selectedTab, $selectedTab)
        .environment(\.beanEditRequest, $beanEditRequest)
        .onChange(of: recipeImportCount) { _, _ in selectedTab = 1 }
        .tint(StudioTheme.accent)
        .preferredColorScheme(.dark)
        .task {
            await BrewLiveActivityManager.shared.endSimulationActivities()
            do {
                try LocalLibrary.seedIfNeeded(in: modelContext)
                #if DEBUG
                try LocalLibrary.seedHistoryPreviewIfRequested(in: modelContext)
                try LocalLibrary.seedBeanRelationshipPreviewIfRequested(in: modelContext)
                #endif
                // Compact older telemetry on launch while keeping every brew summary.
                try LocalLibrary.compactHistory(in: modelContext)
            } catch {
                seedError = error.localizedDescription
            }
            await Task.yield()
            withAnimation(.easeOut(duration: 0.4)) {
                isLaunching = false
            }
        }
        .task(priority: .utility) {
            // Let the first frame become interactive before incrementally
            // indexing legacy JSON records in small, yielding batches.
            try? await Task.sleep(for: .seconds(1))
            try? await LocalLibrary.backfillIndexedMetadata(in: modelContext)
        }
        .alert("Local database error", isPresented: .constant(seedError != nil)) {
            Button("OK") { seedError = nil }
        } message: {
            Text(seedError ?? "")
        }
        .fullScreenCover(
            item: Binding(
                get: { brewSession.presentation },
                set: { value in
                    if value == nil { brewSession.dismiss() }
                }
            )
        ) { presentation in
            NavigationStack {
                BrewSessionView(
                    recipe: presentation.recipe,
                    mode: presentation.mode,
                    sessionID: presentation.id,
                    resumedAt: presentation.startedAt,
                    restoredWeightBaseline: presentation.weightBaseline,
                    restoredWaterBaseline: presentation.waterBaseline,
                    restoredWater: presentation.water,
                    restoredWeight: presentation.weight,
                    restoredTemperature: presentation.temperature,
                    restoredActivePourIndex: presentation.activePourIndex,
                    restoredPhase: presentation.currentPhase,
                    restoredSamples: presentation.samples,
                    restoredExtractionStartedAt: presentation.extractionStartedAt,
                    restoredExtractionElapsed: presentation.extractionElapsed
                )
            }
        }
    }
}

private struct StartupLoadingView: View {
    var body: some View {
        ZStack {
            StudioBackground()
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(StudioTheme.panel)
                        .frame(width: 118, height: 118)
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(StudioTheme.accent.opacity(0.26), lineWidth: 1)
                        }
                    Image(systemName: StudioSymbol.bean)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(
                            StudioTheme.accent
                        )
                        .symbolEffect(.pulse.byLayer, options: .repeating)
                }

                VStack(spacing: 7) {
                    Text("xBloom")
                        .font(.largeTitle.weight(.bold))
                    Text("Preparing your coffee studio")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                }

                ProgressView()
                    .controlSize(.small)
                    .tint(StudioTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("xBloom is preparing your coffee studio")
    }
}

/// Consistent machine access on the leading side of every main page.
struct MachineToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            MachineConnectionButton()
        }
    }
}
