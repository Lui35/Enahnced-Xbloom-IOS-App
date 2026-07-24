import SwiftData
import SwiftUI

@main
struct XBloomApp: App {
    @State private var machine = XBloomBLEClient()
    @State private var gemini = GeminiService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(machine)
                .environment(gemini)
        }
        .modelContainer(for: [StoredBean.self, StoredRecipe.self, StoredBrew.self])
    }
}
