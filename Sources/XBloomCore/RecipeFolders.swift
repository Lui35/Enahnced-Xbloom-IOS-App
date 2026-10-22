import Foundation

public enum RecipeFolderKey: Hashable, Sendable {
    case bean(UUID)
    case generalHot
    case generalIced
    case unavailableBeans

    public static func key(for recipe: Recipe, beanIDs: Set<UUID>) -> Self {
        if let id = recipe.beanID { return beanIDs.contains(id) ? .bean(id) : .unavailableBeans }
        return recipe.brewStyle == .iced ? .generalIced : .generalHot
    }
}

public struct RecipeFolder: Identifiable, Sendable {
    public let id: RecipeFolderKey
    public let title: String
    public let recipeIDs: [UUID]
}

public enum RecipeFolders {
    /// Identity, rather than a bean's display name, keeps separate bags separate.
    public static func make(beans: [BeanProfile], recipes: [Recipe], includeEmptyBeans: Bool = true) -> [RecipeFolder] {
        let ids = Set(beans.map(\.id))
        let groups = Dictionary(grouping: recipes) { RecipeFolderKey.key(for: $0, beanIDs: ids) }
        var result = beans.compactMap { bean -> RecipeFolder? in
            let key = RecipeFolderKey.bean(bean.id)
            let members = groups[key] ?? []
            guard !members.isEmpty || (includeEmptyBeans && !bean.archived) else { return nil }
            return RecipeFolder(id: key, title: bean.name, recipeIDs: members.map(\.id))
        }
        for (key, title) in [(RecipeFolderKey.generalHot, "General hot recipes"), (.generalIced, "General iced recipes"), (.unavailableBeans, "Unavailable beans")] {
            if let members = groups[key], !members.isEmpty {
                result.append(RecipeFolder(id: key, title: title, recipeIDs: members.map(\.id)))
            }
        }
        return result
    }
}

/// A personal quality target, not an expiry or food-safety assessment.
public struct BeanBrewWindow: Sendable {
    public let ageInDays: Int?
    public let daysRemaining: Int?

    public init(roastDate: Date?, targetDays: Int, now: Date = Date(), calendar: Calendar = .current) {
        guard let roastDate else { ageInDays = nil; daysRemaining = nil; return }
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: roastDate), to: calendar.startOfDay(for: now)).day ?? 0
        ageInDays = age
        daysRemaining = age < 0 ? nil : min(365, max(1, targetDays)) - age
    }
}
