import Foundation
import SwiftData
import XBloomCore

#if DEBUG
extension LocalLibrary {
    static func seedBeanRelationshipPreviewIfRequested(in context: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("-seedBeanRelationshipPreview") else { return }
        let previewName = "Relationship Preview Bean"
        var beanDescriptor = FetchDescriptor<StoredBean>(
            predicate: #Predicate { $0.name == previewName }
        )
        beanDescriptor.fetchLimit = 1
        guard try context.fetch(beanDescriptor).isEmpty else { return }

        let bean = BeanProfile(
            name: previewName,
            roaster: "Visual QA Roasters",
            country: "Ethiopia",
            region: "Guji",
            producer: "Test Lot",
            variety: "74110",
            process: "Washed",
            roastLevel: "Light",
            acidityLevel: 4,
            tastingNotes: "Jasmine, peach, bergamot",
            desiredCup: "Sweet, floral, high clarity",
            initialWeightGrams: 250,
            remainingWeightGrams: 196
        )
        var recipe = RecipeLibrary.defaults[0]
        recipe.id = UUID()
        recipe.name = "Guji Clarity"
        recipe.beanID = bean.id
        recipe.generatedByAI = true
        recipe.aiDescription = "A clear, floral profile linked to this bean."

        context.insert(StoredBean(profile: bean))
        context.insert(StoredRecipe(recipe: recipe))
        for (daysAgo, rating) in [(1, 5), (3, 4)] {
            let entry = BrewHistoryEntry(
                recipeID: recipe.id,
                recipeName: recipe.name,
                beanID: bean.id,
                beanName: bean.name,
                completedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date(),
                duration: 168,
                water: Double(recipe.totalWater),
                coffeeWeight: 252,
                steps: recipe.pours.count,
                rating: rating,
                samples: [
                    BrewSample(elapsed: 0, water: 0, coffeeWeight: 0, temperature: 90),
                    BrewSample(elapsed: 55, water: 50, coffeeWeight: 34, temperature: 90),
                    BrewSample(elapsed: 112, water: 169, coffeeWeight: 142, temperature: 90),
                    BrewSample(elapsed: 168, water: Double(recipe.totalWater), coffeeWeight: 252, temperature: 89),
                ],
                recipeSnapshot: recipe,
                beanSnapshot: bean
            )
            context.insert(StoredBrew(entry: entry))
        }
        try context.save()
    }

    static func seedHistoryPreviewIfRequested(in context: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("-seedHistoryPreview") else { return }
        var historyDescriptor = FetchDescriptor<StoredBrew>()
        historyDescriptor.fetchLimit = 1
        guard try context.fetch(historyDescriptor).isEmpty else { return }

        let bean = BeanProfile(
            name: "Sidama Bombe",
            roaster: "Test Roaster",
            country: "Ethiopia",
            region: "Sidama",
            variety: "74158",
            process: "Natural",
            roastLevel: "Light",
            tastingNotes: "Peach, jasmine, honey"
        )
        var recipe = RecipeLibrary.defaults[0]
        recipe.id = UUID()
        recipe.name = "Peach Clarity AI"
        recipe.beanID = bean.id
        recipe.generatedByAI = true
        recipe.servings = 1
        recipe.aiDescription = "Designed by Gemini to emphasize peach sweetness and floral clarity."

        let storedBean = StoredBean(profile: bean)
        let storedRecipe = StoredRecipe(recipe: recipe)
        let entry = BrewHistoryEntry(
            recipeID: recipe.id,
            recipeName: recipe.name,
            beanID: bean.id,
            beanName: bean.name,
            duration: 176,
            water: Double(recipe.totalWater),
            coffeeWeight: 246,
            steps: recipe.pours.count,
            samples: [
                BrewSample(elapsed: 0, water: 0, coffeeWeight: 0, temperature: 90),
                BrewSample(elapsed: 45, water: 70, coffeeWeight: 42, temperature: 93),
                BrewSample(elapsed: 100, water: 180, coffeeWeight: 142, temperature: 92),
                BrewSample(elapsed: 176, water: Double(recipe.totalWater), coffeeWeight: 246, temperature: 91),
            ],
            recipeSnapshot: recipe,
            beanSnapshot: bean
        )
        context.insert(storedBean)
        context.insert(storedRecipe)
        context.insert(StoredBrew(entry: entry))
        try context.save()
    }
}
#endif
