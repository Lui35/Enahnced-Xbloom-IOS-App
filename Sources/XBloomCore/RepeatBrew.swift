import Foundation

public enum RepeatBrew {
    /// Only a snapshot can reproduce a historical brew. Never substitute an
    /// edited library recipe or derive the dose from measured cup yield.
    public static func recipe(from entry: BrewHistoryEntry) throws -> Recipe {
        guard let recipe = entry.recipeSnapshot else { throw RepeatError.missingSnapshot }
        try RecipeValidator.requireSafe(recipe)
        return recipe
    }

    public enum RepeatError: LocalizedError {
        case missingSnapshot
        public var errorDescription: String? {
            "This older brew has no saved recipe snapshot. Choose a recipe from your library instead."
        }
    }
}
