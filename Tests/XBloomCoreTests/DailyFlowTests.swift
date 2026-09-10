import Foundation
import Testing
@testable import XBloomCore

@Test func repeatBrewUsesSnapshotDoseAndEveryPour() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.dose = 17.3
    let brew = BrewHistoryEntry(recipeID: recipe.id, recipeName: recipe.name,
        beanID: nil, beanName: nil, duration: 120, water: 100, coffeeWeight: 80,
        steps: recipe.pours.count, recipeSnapshot: recipe, outcome: .stopped)
    var editedLibraryRecipe = recipe
    editedLibraryRecipe.dose = 25
    editedLibraryRecipe.pours = []
    let repeated = try RepeatBrew.recipe(from: brew)
    #expect(repeated == recipe)
    #expect(repeated != editedLibraryRecipe)
    #expect(repeated.dose == 17.3)
}

@Test func repeatBrewDoesNotInventMissingHistory() {
    let brew = BrewHistoryEntry(recipeID: nil, recipeName: "Legacy", beanID: nil,
        beanName: nil, duration: 120, water: 240, coffeeWeight: 210, steps: 3)
    #expect(throws: (any Error).self) { try RepeatBrew.recipe(from: brew) }
}

@Test func favoritesRemainOptionalForOlderRecipesAndRoundTrip() throws {
    let original = RecipeLibrary.defaults[0]
    let old = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(original))
    #expect(old.isFavorite != true)
    var favorite = original
    favorite.isFavorite = true
    let restored = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(favorite))
    #expect(restored.isFavorite == true)
    #expect(restored.pours == original.pours)
}

@Test func editsDuringSyncRemainPendingUntilTheirOwnUploadCompletes() {
    var state = LibrarySyncState()
    let uploading = state.localRevision
    state.recordLocalSave()
    state.acknowledge(revision: uploading)
    #expect(state.hasPendingChanges)
    state.acknowledge(revision: state.localRevision)
    #expect(!state.hasPendingChanges)
    state.recordLocalSave()
    #expect(state.hasPendingChanges)
    // A failed upload never acknowledges anything.
    state.acknowledge(revision: uploading)
    #expect(state.hasPendingChanges)
}
