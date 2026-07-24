import Foundation
import SwiftData
import XBloomCore

@Model
final class StoredBean {
    @Attribute(.unique) var id: UUID
    var name: String
    var roaster: String
    var remainingWeightGrams: Double
    var archived: Bool
    var updatedAt: Date
    var payload: Data

    init(profile: BeanProfile) {
        id = profile.id
        name = profile.name
        roaster = profile.roaster
        remainingWeightGrams = profile.remainingWeightGrams
        archived = profile.archived
        updatedAt = Date()
        payload = (try? Self.encoder.encode(profile)) ?? Data()
    }

    var profile: BeanProfile? {
        try? Self.decoder.decode(BeanProfile.self, from: payload)
    }

    func update(with profile: BeanProfile) {
        name = profile.name
        roaster = profile.roaster
        remainingWeightGrams = profile.remainingWeightGrams
        archived = profile.archived
        updatedAt = Date()
        payload = (try? Self.encoder.encode(profile)) ?? payload
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

@Model
final class StoredRecipe {
    @Attribute(.unique) var id: UUID
    var name: String
    var roaster: String
    var origin: String
    var updatedAt: Date
    var payload: Data

    init(recipe: Recipe) {
        id = recipe.id
        name = recipe.name
        roaster = recipe.roaster
        origin = recipe.origin
        updatedAt = Date()
        payload = (try? JSONEncoder().encode(recipe)) ?? Data()
    }

    var recipe: Recipe? {
        try? JSONDecoder().decode(Recipe.self, from: payload)
    }

    func update(with recipe: Recipe) {
        name = recipe.name
        roaster = recipe.roaster
        origin = recipe.origin
        updatedAt = Date()
        payload = (try? JSONEncoder().encode(recipe)) ?? payload
    }
}

@Model
final class StoredBrew {
    @Attribute(.unique) var id: UUID
    var recipeName: String
    var beanName: String?
    var completedAt: Date
    var duration: TimeInterval
    var rating: Int?
    var payload: Data

    init(entry: BrewHistoryEntry) {
        id = entry.id
        recipeName = entry.recipeName
        beanName = entry.beanName
        completedAt = entry.completedAt
        duration = entry.duration
        rating = entry.rating
        payload = (try? Self.encoder.encode(entry)) ?? Data()
    }

    var entry: BrewHistoryEntry? {
        try? Self.decoder.decode(BrewHistoryEntry.self, from: payload)
    }

    func update(with entry: BrewHistoryEntry) {
        recipeName = entry.recipeName
        beanName = entry.beanName
        completedAt = entry.completedAt
        duration = entry.duration
        rating = entry.rating
        payload = (try? Self.encoder.encode(entry)) ?? payload
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

@MainActor
enum LocalLibrary {
    static func seedIfNeeded(in context: ModelContext) throws {
        var descriptor = FetchDescriptor<StoredRecipe>()
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return }
        RecipeLibrary.defaults.forEach { context.insert(StoredRecipe(recipe: $0)) }
        try context.save()
    }

    static func recordCompletedBrew(
        recipe: Recipe,
        bean: StoredBean?,
        startedAt: Date,
        telemetry: XBloomTelemetry,
        samples: [BrewSample],
        in context: ModelContext
    ) throws {
        let entry = BrewHistoryEntry(
            recipeID: recipe.id,
            recipeName: recipe.name,
            beanID: bean?.id,
            beanName: bean?.name,
            duration: Date().timeIntervalSince(startedAt),
            water: telemetry.waterVolume ?? Double(recipe.totalWater),
            coffeeWeight: telemetry.weight ?? 0,
            steps: recipe.pours.count,
            samples: samples,
            recipeSnapshot: recipe,
            beanSnapshot: bean?.profile
        )
        context.insert(StoredBrew(entry: entry))

        if let bean, var profile = bean.profile {
            profile = Brewing.deductDose(recipe.dose, from: profile)
            bean.update(with: profile)
        }
        try context.save()
    }

    #if DEBUG
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
    #endif
}
