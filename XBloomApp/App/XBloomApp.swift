import Combine
import SwiftData
import SwiftUI

@main
struct XBloomApp: App {
    @State private var machine = XBloomBLEClient()
    @State private var cloud: SupabaseService
    @State private var gemini: GeminiService
    @State private var brewSession = BrewSessionCoordinator()
    @State private var recipeGeneration = RecipeGenerationCoordinator()

    init() {
        let cloud = SupabaseService()
        _cloud = State(initialValue: cloud)
        _gemini = State(initialValue: GeminiService(cloud: cloud))
    }

    var body: some Scene {
        WindowGroup {
            CloudBootstrapView()
                .environment(machine)
                .environment(cloud)
                .environment(gemini)
                .environment(brewSession)
                .environment(recipeGeneration)
        }
        .modelContainer(
            for: [
                StoredBean.self,
                StoredRecipe.self,
                StoredBrew.self,
                StoredMaintenanceEvent.self,
                CloudSyncMetadata.self,
            ]
        )
    }
}

private struct CloudBootstrapView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SupabaseService.self) private var cloud
    @Environment(RecipeGenerationCoordinator.self) private var recipeGeneration

    var body: some View {
        RootView()
            .task {
                #if DEBUG
                recipeGeneration.seedPreviewPendingIfRequested()
                #endif
                await cloud.refreshSession()
            }
            .task(id: cloud.userID) {
                guard cloud.isAuthenticated else { return }
                try? await Task.sleep(for: .seconds(1))
                _ = try? await cloud.sync(in: modelContext)
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
