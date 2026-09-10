import SwiftData
import SwiftUI

struct FavoriteRecipeButton: View {
    @Environment(\.modelContext) private var modelContext
    let stored: StoredRecipe
    @State private var errorMessage: String?

    var body: some View {
        Button {
            guard let original = stored.recipe else { return }
            var updated = original
            updated.isFavorite = original.isFavorite != true
            let date = stored.updatedAt
            stored.update(with: updated)
            do { try modelContext.save() }
            catch {
                stored.update(with: original)
                stored.updatedAt = date
                errorMessage = error.localizedDescription
            }
        } label: {
            Label(stored.recipe?.isFavorite == true ? "Favorited" : "Add to favorites",
                  systemImage: stored.recipe?.isFavorite == true ? "heart.fill" : "heart")
        }
        .tint(StudioTheme.danger)
        .alert("Could not save favorite", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }
}
