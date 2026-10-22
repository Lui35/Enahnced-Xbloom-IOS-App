import Foundation
import Testing
@testable import XBloomCore

@Test func recipeLinkRoundTripsAllBrewingSettingsWithoutPrivateRelationships() throws {
    var original = RecipeLibrary.defaults[0]
    original.name = "قهوة ☕️ / Sweet & bright"
    original.beanID = UUID()
    original.parentRecipeID = UUID()
    original.sourceBrewID = UUID()
    original.isFavorite = true
    original.brewStyle = .iced
    original.iceGrams = 100
    original.pours[0].agitationAfter = true
    let link = try RecipeShareLink.make(for: original)
    let shared = try RecipeShareLink.decode(link)
    #expect(shared.name == original.name)
    #expect(shared.pours == original.pours)
    #expect(shared.dose == original.dose)
    #expect(shared.brewStyle == .iced)
    #expect(shared.iceGrams == 100)
    #expect(shared.beanID == nil)
    #expect(shared.parentRecipeID == nil)
    #expect(shared.sourceBrewID == nil)
    #expect(shared.isFavorite == nil)
    let imported = try RecipeShareLink.importedCopy(of: shared)
    #expect(imported.id != original.id)
    #expect(imported.pours[0].id != original.pours[0].id)
    #expect(imported.pours[0].volume == original.pours[0].volume)
}

@Test func recipeLinksRejectMalformedAmbiguousAndOversizedInput() throws {
    let valid = try RecipeShareLink.make(for: RecipeLibrary.defaults[0])
    let invalid = ["xbloom://login-callback", "https://recipe?data=abc", "xbloom://recipe?data=%%%",
                   "xbloom://recipe?data=", valid.absoluteString + "&data=abc",
                   "xbloom://recipe?data=" + String(repeating: "A", count: 16_001)]
    for raw in invalid {
        let url = try #require(URL(string: raw))
        #expect(throws: (any Error).self) { try RecipeShareLink.decode(url) }
    }
}

@Test func recipeLinksRejectUnsafeAndFutureRecipesWithoutOverflow() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.pours[0].volume = Int.max
    #expect(throws: (any Error).self) { try RecipeShareLink.make(for: recipe) }
    recipe = RecipeLibrary.defaults[0]
    recipe.pours[0].temperature = 120
    // Construct an external payload directly to test the receiving boundary.
    struct FuturePayload: Encodable { let version: Int; let recipe: Recipe }
    func externalLink(version: Int, recipe: Recipe) throws -> URL {
        let data = try JSONEncoder().encode(FuturePayload(version: version, recipe: recipe))
        let value = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try #require(URL(string: "xbloom://recipe?data=\(value)"))
    }
    #expect(throws: (any Error).self) { try RecipeShareLink.decode(externalLink(version: 1, recipe: recipe)) }
    #expect(throws: (any Error).self) {
        try RecipeShareLink.decode(externalLink(version: 2, recipe: RecipeLibrary.defaults[0]))
    }
}
