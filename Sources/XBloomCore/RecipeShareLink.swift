import Foundation

/// A complete recipe snapshot. Links work offline and never grant access to a library.
public enum RecipeShareLink {
    public static let maximumURLLength = 16_000

    private struct Payload: Codable {
        let version: Int
        let recipe: Recipe
    }

    public enum LinkError: LocalizedError {
        case invalidLink
        case unsupportedVersion
        case tooLarge
        case invalidRecipe

        public var errorDescription: String? {
            switch self {
            case .invalidLink: "This is not a valid xBloom recipe link."
            case .unsupportedVersion: "This recipe link needs a newer version of xBloom."
            case .tooLarge: "This recipe is too large for a sharing link. Use a recipe file instead."
            case .invalidRecipe: "This shared recipe contains unsupported brewing settings."
            }
        }
    }

    public static func recognizes(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "xbloom" && url.host?.lowercased() == "recipe"
    }

    public static func make(for recipe: Recipe) throws -> URL {
        try validate(recipe)
        let data = try JSONEncoder().encode(Payload(version: 1, recipe: portable(recipe)))
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "xbloom"
        components.host = "recipe"
        components.queryItems = [URLQueryItem(name: "data", value: encoded)]
        guard let url = components.url else { throw LinkError.invalidLink }
        guard url.absoluteString.utf8.count <= maximumURLLength else { throw LinkError.tooLarge }
        return url
    }

    public static func decode(_ url: URL) throws -> Recipe {
        guard recognizes(url), url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else {
            throw LinkError.invalidLink
        }
        guard url.absoluteString.utf8.count <= maximumURLLength else { throw LinkError.tooLarge }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.count == 1, items.first?.name == "data", let value = items.first?.value,
              !value.isEmpty,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw LinkError.invalidLink
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw LinkError.invalidLink
        }
        guard payload.version == 1 else { throw LinkError.unsupportedVersion }
        try validate(payload.recipe)
        return portable(payload.recipe)
    }

    /// Import as a new recipe so another person's IDs can never overwrite local work.
    public static func importedCopy(of recipe: Recipe) throws -> Recipe {
        try validate(recipe)
        var copy = portable(recipe)
        copy.id = UUID()
        copy.pours = copy.pours.map { pour in
            var copy = pour
            copy.id = UUID()
            return copy
        }
        return copy
    }

    private static func portable(_ recipe: Recipe) -> Recipe {
        var copy = recipe
        copy.beanID = nil
        copy.parentRecipeID = nil
        copy.sourceBrewID = nil
        copy.isFavorite = nil
        return copy
    }

    private static func validate(_ recipe: Recipe) throws {
        // Bound untrusted integers before the validator sums volumes or computes ratios.
        guard (1...8).contains(recipe.pours.count),
              recipe.pours.allSatisfy({ (0...240).contains($0.volume) }),
              recipe.dose.isFinite, recipe.pours.allSatisfy({ $0.flowRate.isFinite }),
              (0...500).contains(recipe.iceGrams),
              recipe.servings.map({ (1...10).contains($0) }) ?? true else {
            throw LinkError.invalidRecipe
        }
        try RecipeValidator.requireSafe(recipe)
        guard recipe.totalWater > 0 else { throw LinkError.invalidRecipe }
    }
}
