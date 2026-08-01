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
    @Transient private var cachedPayload: Data?
    @Transient private var cachedProfile: BeanProfile?

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
        if cachedPayload == payload { return cachedProfile }
        let decoded = try? Self.decoder.decode(BeanProfile.self, from: payload)
        cachedPayload = payload
        cachedProfile = decoded
        return decoded
    }

    func update(with profile: BeanProfile) {
        name = profile.name
        roaster = profile.roaster
        remainingWeightGrams = profile.remainingWeightGrams
        archived = profile.archived
        updatedAt = Date()
        payload = (try? Self.encoder.encode(profile)) ?? payload
        cachedPayload = payload
        cachedProfile = profile
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
    var brewStyleRaw: String?
    var generatedByAI: Bool?
    var servings: Int?
    var beanID: UUID?
    var updatedAt: Date
    var payload: Data
    @Transient private var cachedPayload: Data?
    @Transient private var cachedRecipe: Recipe?

    init(recipe: Recipe) {
        id = recipe.id
        name = recipe.name
        roaster = recipe.roaster
        origin = recipe.origin
        brewStyleRaw = recipe.brewStyle.rawValue
        generatedByAI = recipe.generatedByAI
        servings = recipe.servings
        beanID = recipe.beanID
        updatedAt = Date()
        payload = (try? JSONEncoder().encode(recipe)) ?? Data()
    }

    var recipe: Recipe? {
        if cachedPayload == payload { return cachedRecipe }
        let decoded = try? JSONDecoder().decode(Recipe.self, from: payload)
        cachedPayload = payload
        cachedRecipe = decoded
        return decoded
    }

    func update(with recipe: Recipe) {
        name = recipe.name
        roaster = recipe.roaster
        origin = recipe.origin
        brewStyleRaw = recipe.brewStyle.rawValue
        generatedByAI = recipe.generatedByAI
        servings = recipe.servings
        beanID = recipe.beanID
        updatedAt = Date()
        payload = (try? JSONEncoder().encode(recipe)) ?? payload
        cachedPayload = payload
        cachedRecipe = recipe
    }

    var indexedBrewStyle: BrewStyle? {
        brewStyleRaw.flatMap(BrewStyle.init(rawValue:))
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
    var recipeID: UUID?
    var beanID: UUID?
    var brewStyleRaw: String?
    var generatedByAI: Bool?
    var wasSimulated: Bool?
    var servings: Int?
    var water: Double?
    var coffeeWeight: Double?
    var steps: Int?
    var payload: Data
    @Transient private var cachedPayload: Data?
    @Transient private var cachedEntry: BrewHistoryEntry?

    init(entry: BrewHistoryEntry) {
        id = entry.id
        recipeName = entry.recipeName
        beanName = entry.beanName
        completedAt = entry.completedAt
        duration = entry.duration
        rating = entry.rating
        recipeID = entry.recipeID
        beanID = entry.beanID
        brewStyleRaw = entry.recipeSnapshot?.brewStyle.rawValue
        generatedByAI = entry.recipeSnapshot?.generatedByAI
        wasSimulated = entry.wasSimulated
        servings = entry.recipeSnapshot?.servings
        water = entry.water
        coffeeWeight = entry.coffeeWeight
        steps = entry.steps
        payload = (try? Self.encoder.encode(entry)) ?? Data()
    }

    var entry: BrewHistoryEntry? {
        if cachedPayload == payload { return cachedEntry }
        let decoded = try? Self.decoder.decode(BrewHistoryEntry.self, from: payload)
        cachedPayload = payload
        cachedEntry = decoded
        return decoded
    }

    func update(with entry: BrewHistoryEntry) {
        recipeName = entry.recipeName
        beanName = entry.beanName
        completedAt = entry.completedAt
        duration = entry.duration
        rating = entry.rating
        recipeID = entry.recipeID
        beanID = entry.beanID
        brewStyleRaw = entry.recipeSnapshot?.brewStyle.rawValue
        generatedByAI = entry.recipeSnapshot?.generatedByAI
        wasSimulated = entry.wasSimulated
        servings = entry.recipeSnapshot?.servings
        water = entry.water
        coffeeWeight = entry.coffeeWeight
        steps = entry.steps
        payload = (try? Self.encoder.encode(entry)) ?? payload
        cachedPayload = payload
        cachedEntry = entry
    }

    var indexedBrewStyle: BrewStyle? {
        brewStyleRaw.flatMap(BrewStyle.init(rawValue:))
    }

    func backfillIndexIfNeeded() {
        guard let entry else { return }
        recipeID = recipeID ?? entry.recipeID
        beanID = beanID ?? entry.beanID
        brewStyleRaw = brewStyleRaw ?? entry.recipeSnapshot?.brewStyle.rawValue
        generatedByAI = generatedByAI ?? entry.recipeSnapshot?.generatedByAI
        wasSimulated = wasSimulated ?? entry.wasSimulated
        servings = servings ?? entry.recipeSnapshot?.servings
        water = water ?? entry.water
        coffeeWeight = coffeeWeight ?? entry.coffeeWeight
        steps = steps ?? entry.steps
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

    static func backfillIndexedMetadata(in context: ModelContext) async throws {
        while !Task.isCancelled {
            var recipeDescriptor = FetchDescriptor<StoredRecipe>(
                predicate: #Predicate { $0.brewStyleRaw == nil }
            )
            recipeDescriptor.fetchLimit = 40
            let recipes = try context.fetch(recipeDescriptor)
            for stored in recipes {
                guard let recipe = stored.recipe else {
                    stored.brewStyleRaw = "unknown"
                    continue
                }
                stored.brewStyleRaw = recipe.brewStyle.rawValue
                stored.generatedByAI = recipe.generatedByAI
                stored.servings = recipe.servings
                stored.beanID = recipe.beanID
            }

            var brewDescriptor = FetchDescriptor<StoredBrew>(
                predicate: #Predicate { $0.brewStyleRaw == nil }
            )
            brewDescriptor.fetchLimit = 40
            let brews = try context.fetch(brewDescriptor)
            for brew in brews {
                if brew.entry == nil {
                    brew.brewStyleRaw = "unknown"
                } else {
                    brew.backfillIndexIfNeeded()
                    brew.brewStyleRaw = brew.brewStyleRaw ?? "unknown"
                }
            }

            guard !recipes.isEmpty || !brews.isEmpty else { return }
            try context.save()
            await Task.yield()
        }
    }

    static func recordCompletedBrew(
        id: UUID = UUID(),
        recipe: Recipe,
        bean: StoredBean?,
        startedAt: Date,
        telemetry: XBloomTelemetry,
        samples: [BrewSample],
        durationOverride: TimeInterval? = nil,
        wasSimulated: Bool = false,
        in context: ModelContext
    ) throws {
        var existingDescriptor = FetchDescriptor<StoredBrew>(
            predicate: #Predicate { $0.id == id }
        )
        existingDescriptor.fetchLimit = 1
        guard try context.fetch(existingDescriptor).isEmpty else { return }

        let entry = BrewHistoryEntry(
            id: id,
            recipeID: recipe.id,
            recipeName: recipe.name,
            beanID: bean?.id,
            beanName: bean?.name,
            duration: durationOverride ?? Date().timeIntervalSince(startedAt),
            water: telemetry.waterVolume ?? Double(recipe.totalWater),
            coffeeWeight: telemetry.weight ?? 0,
            steps: recipe.pours.count,
            samples: samples,
            recipeSnapshot: recipe,
            beanSnapshot: bean?.profile,
            wasSimulated: wasSimulated
        )
        context.insert(StoredBrew(entry: entry))

        if let bean, var profile = bean.profile {
            profile = Brewing.deductDose(recipe.dose, from: profile)
            bean.update(with: profile)
        }
        try context.save()
    }

    #if DEBUG
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
    #endif
}
