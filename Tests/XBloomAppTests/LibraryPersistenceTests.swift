import Foundation
import SwiftData
import Testing
import XBloomCore
@testable import xBloom

@MainActor
func testContainer() throws -> ModelContainer {
    try ModelContainer(
        for: StoredBean.self, StoredRecipe.self, StoredBrew.self,
        StoredMaintenanceEvent.self, CloudSyncMetadata.self, StoredRecipeJobReceipt.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

@Suite(.serialized)
@MainActor
struct LibraryPersistenceTests {
    @Test func quickFeedbackUpdatesExistingBrewWithoutChangingUsageOrLineage() throws {
        let container = try testContainer()
        let context = container.mainContext
        let recipe = RecipeLibrary.defaults[0]
        let enhancedID = UUID()
        let original = BrewHistoryEntry(recipeID: recipe.id, recipeName: recipe.name,
            beanID: nil, beanName: nil, duration: 120, water: 250, coffeeWeight: 220,
            steps: recipe.pours.count, recipeSnapshot: recipe,
            enhancementGoals: ["More sweetness"], enhancedRecipeID: enhancedID)
        let stored = StoredBrew(entry: original)
        context.insert(stored)
        try context.save()
        try LocalLibrary.saveFeedback(for: stored, rating: 4, tags: ["Already close"], notes: "  Sweet cup  ", in: context)
        let reader = ModelContext(container)
        let saved = try #require(reader.fetch(FetchDescriptor<StoredBrew>()).first?.entry)
        #expect(try reader.fetchCount(FetchDescriptor<StoredBrew>()) == 1)
        #expect(saved.rating == 4)
        #expect(saved.notes == "Sweet cup")
        #expect(saved.feedbackTags == ["Already close"])
        #expect(saved.enhancedRecipeID == enhancedID)
        #expect(saved.enhancementGoals == original.enhancementGoals)
        #expect(saved.recipeSnapshot == recipe)
    }

    @Test func favoriteSurvivesStoredRecipeReload() throws {
        let container = try testContainer()
        var recipe = RecipeLibrary.defaults[0]
        recipe.isFavorite = true
        container.mainContext.insert(StoredRecipe(recipe: recipe))
        try container.mainContext.save()
        let restored = try ModelContext(container).fetch(FetchDescriptor<StoredRecipe>()).first?.recipe
        #expect(restored?.isFavorite == true)
        #expect(restored?.id == recipe.id)
    }

    @Test func deletingARecipeKeepsUsageFeedbackAndTheOriginalSnapshot() throws {
        let container = try testContainer()
        let context = container.mainContext
        let bean = StoredBean(profile: BeanProfile(name: "Coffee", remainingWeightGrams: 200))
        context.insert(bean)
        var original = RecipeLibrary.defaults[0]
        original.beanID = bean.id
        original.dose = 18
        original.useGrinder = true
        var edited = original
        edited.dose = 25 // Editing the library must not rewrite historical usage.
        let storedRecipe = StoredRecipe(recipe: edited)
        context.insert(storedRecipe)
        let serviceDate = Date(timeIntervalSince1970: 1_000)
        let service = StoredMaintenanceEvent(task: .grinderTablets, performedAt: serviceDate)
        context.insert(service)
        for offset in [0.0, 100, 200] {
            context.insert(StoredBrew(entry: BrewHistoryEntry(recipeID: original.id, recipeName: original.name,
                beanID: bean.id, beanName: bean.name, completedAt: serviceDate.addingTimeInterval(offset),
                duration: 120, water: 270, coffeeWeight: 240, steps: original.pours.count,
                rating: 4, notes: "Keep this feedback", recipeSnapshot: original, beanSnapshot: bean.profile)))
        }
        try context.save()
        try LocalLibrary.delete(recipe: storedRecipe, in: context)
        let reader = ModelContext(container)
        #expect(try reader.fetchCount(FetchDescriptor<StoredRecipe>()) == 0)
        #expect(try reader.fetchCount(FetchDescriptor<StoredBean>()) == 1)
        #expect(try reader.fetchCount(FetchDescriptor<StoredMaintenanceEvent>()) == 1)
        let entries = try reader.fetch(FetchDescriptor<StoredBrew>()).compactMap(\.entry)
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.rating == 4 && $0.notes == "Keep this feedback" && $0.recipeSnapshot?.dose == 18 })
        let usage = Maintenance.usage(brews: entries, servicedAt: serviceDate)
        #expect(usage.brews == 2)
        #expect(usage.groundGrams == 36)
    }

    @Test func deletingABagAndItsRecipesDoesNotResetDueMaintenance() throws {
        let container = try testContainer()
        let context = container.mainContext
        let bean = StoredBean(profile: BeanProfile(name: "Finished bag"))
        let other = StoredBean(profile: BeanProfile(name: "Keep this bag"))
        context.insert(bean)
        context.insert(other)
        var recipe = RecipeLibrary.defaults[0]
        recipe.beanID = bean.id
        recipe.dose = 18
        recipe.useGrinder = true
        context.insert(StoredRecipe(recipe: recipe))
        var anotherRecipe = RecipeLibrary.defaults[0]
        anotherRecipe.id = UUID()
        anotherRecipe.beanID = other.id
        context.insert(StoredRecipe(recipe: anotherRecipe))
        for _ in 0..<60 {
            context.insert(StoredBrew(entry: BrewHistoryEntry(recipeID: recipe.id, recipeName: recipe.name,
                beanID: bean.id, beanName: bean.name, duration: 120, water: 270, coffeeWeight: 240,
                steps: recipe.pours.count, recipeSnapshot: recipe, beanSnapshot: bean.profile)))
        }
        try context.save()
        try LocalLibrary.delete(bean: bean, in: context)
        let reader = ModelContext(container)
        #expect(try reader.fetch(FetchDescriptor<StoredBean>()).map(\.id) == [other.id])
        #expect(try reader.fetch(FetchDescriptor<StoredRecipe>()).map(\.id) == [anotherRecipe.id])
        let entries = try reader.fetch(FetchDescriptor<StoredBrew>()).compactMap(\.entry)
        let usage = Maintenance.usage(brews: entries, servicedAt: nil)
        #expect(usage.brews == 60)
        #expect(usage.groundGrams == 1_080)
        #expect(Maintenance.status(.grinderTablets, usage: usage).isDue)
        #expect(entries.allSatisfy { $0.beanSnapshot?.name == "Finished bag" })
    }

    @Test func deletionPreservesAvailableDetailsForLegacyHistory() throws {
        let container = try testContainer()
        let context = container.mainContext
        let bean = StoredBean(profile: BeanProfile(name: "Legacy coffee"))
        context.insert(bean)
        var recipe = RecipeLibrary.defaults[0]
        recipe.beanID = bean.id
        context.insert(StoredRecipe(recipe: recipe))
        let entry = BrewHistoryEntry(recipeID: recipe.id, recipeName: recipe.name,
            beanID: bean.id, beanName: bean.name, completedAt: Date(timeIntervalSince1970: 1_000),
            duration: 120, water: 270, coffeeWeight: 240, steps: recipe.pours.count, notes: "Older record")
        context.insert(StoredBrew(entry: entry))
        try context.save()
        try LocalLibrary.delete(bean: bean, in: context)
        let saved = try #require(context.fetch(FetchDescriptor<StoredBrew>()).first?.entry)
        #expect(saved.recipeSnapshot?.id == recipe.id)
        #expect(saved.beanSnapshot?.name == "Legacy coffee")
        #expect(saved.completedAt == entry.completedAt)
        #expect(saved.notes == "Older record")
    }

    @Test func previewsLeaveInventoryAndHistoryUntouched() throws {
        let container = try testContainer()
        let context = container.mainContext
        let bean = StoredBean(profile: BeanProfile(name: "Test", initialWeightGrams: 250, remainingWeightGrams: 250))
        context.insert(bean)
        try context.save()
        try LocalLibrary.recordCompletedBrew(
            recipe: RecipeLibrary.defaults[0], bean: bean, startedAt: Date(),
            telemetry: XBloomTelemetry(), samples: [], wasSimulated: true, in: context
        )
        #expect(bean.remainingWeightGrams == 250)
        #expect(try context.fetchCount(FetchDescriptor<StoredBrew>()) == 0)
    }

    @Test func telemetryCompactionPreservesLifetimeUsageAndFeedback() throws {
        let container = try testContainer()
        let context = container.mainContext
        let now = Date()
        var recipe = RecipeLibrary.defaults[0]
        recipe.dose = 18
        recipe.useGrinder = true
        for day in 0..<301 {
            context.insert(StoredBrew(entry: BrewHistoryEntry(
                recipeID: recipe.id, recipeName: recipe.name, beanID: nil, beanName: nil,
                completedAt: now.addingTimeInterval(-Double(day) * 86_400), duration: 120,
                water: 270, coffeeWeight: 240, steps: recipe.pours.count, rating: 4,
                notes: "Keep this feedback", samples: [BrewSample(elapsed: 1, water: 1, coffeeWeight: 1, temperature: nil)],
                recipeSnapshot: recipe
            )))
        }
        try context.save()
        #expect(try LocalLibrary.compactHistory(in: context) == 281)
        let entries = try context.fetch(FetchDescriptor<StoredBrew>()).compactMap(\.entry)
        #expect(entries.count == 301)
        #expect(entries.filter { !$0.samples.isEmpty }.count == 20)
        #expect(entries.allSatisfy { $0.notes == "Keep this feedback" && $0.rating == 4 && $0.recipeSnapshot != nil })
        let usage = Maintenance.usage(brews: entries, servicedAt: nil, now: now)
        #expect(usage.brews == 301)
        #expect(usage.groundGrams == 5_418)
        #expect(Maintenance.status(.grinderTablets, usage: usage, now: now).isDue)
        #expect(Maintenance.status(.descale, usage: usage, now: now).isDue)
        #expect(try LocalLibrary.compactHistory(in: context) == 0)
    }

    @Test func repeatedCompletionDebitsInventoryOnlyOnce() throws {
        let container = try testContainer()
        let context = container.mainContext
        let bean = StoredBean(profile: BeanProfile(name: "Test", initialWeightGrams: 250, remainingWeightGrams: 250))
        context.insert(bean)
        let recipe = RecipeLibrary.defaults[0]
        let id = UUID()
        for _ in 0..<2 {
            try LocalLibrary.recordCompletedBrew(id: id, recipe: recipe, bean: bean,
                startedAt: Date(), telemetry: XBloomTelemetry(), samples: [], in: context)
        }
        #expect(bean.remainingWeightGrams == 250 - recipe.dose)
        #expect(try context.fetchCount(FetchDescriptor<StoredBrew>()) == 1)
    }
}
