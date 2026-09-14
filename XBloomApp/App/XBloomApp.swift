import Combine
import SwiftData
import SwiftUI

@main
struct XBloomApp: App {
    @State private var machine = XBloomBLEClient()
    @State private var cloud: SupabaseService
    @State private var gemini: GeminiService
    @State private var brewSession = BrewSessionCoordinator()
    @State private var recipeGeneration: RecipeGenerationCoordinator
    @State private var beanImport: BeanImportCoordinator

    init() {
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
            CloudBootstrapView()
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SupabaseService.self) private var cloud
    @Environment(RecipeGenerationCoordinator.self) private var recipeGeneration
    @Environment(BeanImportCoordinator.self) private var beanImport

    var body: some View {
        RootView()
            .task {
                #if DEBUG
                recipeGeneration.seedPreviewPendingIfRequested()
                beanImport.seedPreviewPendingIfRequested()
                #endif
                await cloud.refreshSession()
            }
            .task(id: cloud.userID) {
                recipeGeneration.accountChanged()
                beanImport.accountChanged()
                guard cloud.isAuthenticated else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                _ = try? await cloud.sync(in: modelContext)
                // Recover recipe and bag results saved while the app was closed.
                await recipeGeneration.refresh(context: modelContext)
                await beanImport.refresh(context: modelContext)
            }
            // Also recover late results when returning from the background.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, cloud.isAuthenticated else { return }
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
                Task {
                    await cloud.handleOpenURL(url)
                }
            }
    }
}
