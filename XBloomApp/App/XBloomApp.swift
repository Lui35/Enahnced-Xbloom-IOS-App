import SwiftData
import SwiftUI

@main
struct XBloomApp: App {
    @State private var machine = XBloomBLEClient()
    @State private var gemini = GeminiService()
    @State private var brewSession = BrewSessionCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(machine)
                .environment(gemini)
                .environment(brewSession)
        }
        .modelContainer(for: [StoredBean.self, StoredRecipe.self, StoredBrew.self])
    }
}
