import Combine
import SwiftData
import SwiftUI
import XBloomCore

@main
struct XBloomApp: App {
    @State private var machine = XBloomBLEClient()
    @State private var cloud: SupabaseService
    @State private var gemini: GeminiService
    @State private var brewSession = BrewSessionCoordinator()
    @State private var recipeGeneration: RecipeGenerationCoordinator
    @State private var beanImport: BeanImportCoordinator

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            UserDefaults.standard.removeObject(forKey: "onboarding.completed.v1")
        }
        #endif
        let cloud = SupabaseService()
        let gemini = GeminiService(cloud: cloud)
        _cloud = State(initialValue: cloud)
        _gemini = State(initialValue: gemini)
        _beanImport = State(initialValue: BeanImportCoordinator(cloud: cloud, gemini: gemini))
        _recipeGeneration = State(
            initialValue: RecipeGenerationCoordinator(cloud: cloud, gemini: gemini)
        )
    }

    var body: some Scene {
        WindowGroup {
            LaunchExperienceView {
                CloudBootstrapView()
            }
                .environment(machine)
                .environment(cloud)
                .environment(gemini)
                .environment(brewSession)
                .environment(recipeGeneration)
                .environment(beanImport)
        }
        .modelContainer(
            for: [
                StoredBean.self,
                StoredRecipe.self,
                StoredBrew.self,
                StoredMaintenanceEvent.self,
                CloudSyncMetadata.self,
                StoredRecipeJobReceipt.self,
            ]
        )
    }
}

private struct CloudBootstrapView: View {
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SupabaseService.self) private var cloud
    @Environment(RecipeGenerationCoordinator.self) private var recipeGeneration
    @Environment(BeanImportCoordinator.self) private var beanImport
    @AppStorage("onboarding.completed.v1") private var hasCompletedOnboarding = false
    @State private var sharedRecipe: SharedRecipePreview?
    @State private var recipeLinkError: String?
    @State private var recipeImportCount = 0

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                RootView(recipeImportCount: recipeImportCount)
            } else {
                OnboardingView { hasCompletedOnboarding = true }
            }
        }
            .task(id: hasCompletedOnboarding) {
                guard hasCompletedOnboarding else { return }
                machine.connectOnLaunch()
            }
            .task {
                #if DEBUG
                recipeGeneration.seedPreviewPendingIfRequested()
                beanImport.seedPreviewPendingIfRequested()
                #endif
                await cloud.refreshSession()
            }
            .task(id: "\(cloud.userID?.uuidString ?? "guest")-\(hasCompletedOnboarding)") {
                recipeGeneration.accountChanged()
                beanImport.accountChanged()
                guard hasCompletedOnboarding, cloud.isAuthenticated else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                _ = try? await cloud.sync(in: modelContext)
                // Recover recipe and bag results saved while the app was closed.
                await recipeGeneration.refresh(context: modelContext)
                await beanImport.refresh(context: modelContext)
            }
            // Also recover late results when returning from the background.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, hasCompletedOnboarding, cloud.isAuthenticated else { return }
                Task {
                    if !cloud.isSyncing { _ = try? await cloud.sync(in: modelContext) }
                    await recipeGeneration.refresh(context: modelContext)
                    await beanImport.refresh(context: modelContext)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
                guard let savedContext = notification.object as? ModelContext,
                      savedContext === modelContext else { return }
                cloud.scheduleAutomaticSync(in: modelContext)
            }
            .onOpenURL { url in
                if RecipeShareLink.recognizes(url) {
                    do { sharedRecipe = SharedRecipePreview(recipe: try RecipeShareLink.decode(url)) }
                    catch { recipeLinkError = error.localizedDescription }
                } else {
                    Task { await cloud.handleOpenURL(url) }
                }
            }
            .sheet(item: Binding(
                get: { hasCompletedOnboarding ? sharedRecipe : nil },
                set: { sharedRecipe = $0 }
            )) { item in
                SharedRecipeView(recipe: item.recipe) { recipeImportCount += 1 }
            }
            .alert("Couldn’t open recipe", isPresented: Binding(
                get: { recipeLinkError != nil }, set: { if !$0 { recipeLinkError = nil } }
            )) {
                Button("OK") { recipeLinkError = nil }
            } message: { Text(recipeLinkError ?? "") }
    }
}
