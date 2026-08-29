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
    /// A bag the AI read off a photo and nobody has checked yet.
    ///
    /// Deliberately outside the synced payload: it is a note about this
    /// device's inbox, not a fact about the coffee, and a bean already reviewed
    /// on one phone should not arrive needing review on another. Added after
    /// the first release, so it carries a default.
    var needsVerification: Bool = false
    @Transient private var cachedPayload: Data?
    @Transient private var cachedProfile: BeanProfile?

    init(profile: BeanProfile, needsVerification: Bool = false) {
        id = profile.id
        name = profile.name
        roaster = profile.roaster
        remainingWeightGrams = profile.remainingWeightGrams
        archived = profile.archived
        updatedAt = Date()
        payload = (try? Self.encoder.encode(profile)) ?? Data()
        self.needsVerification = needsVerification
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
    var updatedAt: Date?
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
        updatedAt = Date()
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
        updatedAt = Date()
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

/// One service actually performed on the machine.
///
/// The last-done date each maintenance rule counts from used to be a number in
/// UserDefaults, which stayed on one phone and remembered only the most recent
/// one. A row per service syncs like everything else and keeps the cadence:
/// how often the descale really happens, not just when it last did.
@Model
final class StoredMaintenanceEvent {
    @Attribute(.unique) var id: UUID
    /// `MaintenanceTask.rawValue`. Stored as a string so an unknown task from a
    /// newer build survives a round trip instead of failing to decode.
    var task: String
    var performedAt: Date
    var note: String?
    var updatedAt: Date

    init(id: UUID = UUID(), task: MaintenanceTask, performedAt: Date = Date(), note: String? = nil) {
        self.id = id
        self.task = task.rawValue
        self.performedAt = performedAt
        self.note = note
        updatedAt = Date()
    }

    var maintenanceTask: MaintenanceTask? { MaintenanceTask(rawValue: task) }
}

@Model
final class CloudSyncMetadata {
    @Attribute(.unique) var id: String
    var userID: String
    var knownBeanIDs: Data
    var knownRecipeIDs: Data
    var knownBrewIDs: Data
    /// Added after the first release, so it has to carry a default for the
    /// stores that were written without it.
    var knownMaintenanceIDs: Data = Data()
    var lastSyncedAt: Date?

    init(userID: UUID) {
        id = "cloud-sync"
        self.userID = userID.uuidString
        knownBeanIDs = Data()
        knownRecipeIDs = Data()
        knownBrewIDs = Data()
        knownMaintenanceIDs = Data()
    }

    func knownIDs(for kind: CloudRecordKind) -> Set<UUID> {
        let data: Data
        switch kind {
        case .bean: data = knownBeanIDs
        case .recipe: data = knownRecipeIDs
        case .brew: data = knownBrewIDs
        case .maintenance: data = knownMaintenanceIDs
        }
        return (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }

    func setKnownIDs(_ ids: Set<UUID>, for kind: CloudRecordKind) {
        let data = (try? JSONEncoder().encode(ids)) ?? Data()
        switch kind {
        case .bean: knownBeanIDs = data
        case .recipe: knownRecipeIDs = data
        case .brew: knownBrewIDs = data
        case .maintenance: knownMaintenanceIDs = data
        }
    }
}

enum CloudRecordKind {
    case bean
    case recipe
    case brew
    case maintenance
}

@MainActor
enum LocalLibrary {
    private static let didSeedDefaultRecipesKey = "localLibrary.didSeedDefaultRecipes"

    static func seedIfNeeded(in context: ModelContext) throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSeedDefaultRecipesKey) else { return }

        var descriptor = FetchDescriptor<StoredRecipe>()
        descriptor.fetchLimit = 1
        if !(try context.fetch(descriptor)).isEmpty {
            defaults.set(true, forKey: didSeedDefaultRecipesKey)
            return
        }

        var metadataDescriptor = FetchDescriptor<CloudSyncMetadata>()
        metadataDescriptor.fetchLimit = 1
        if let metadata = try context.fetch(metadataDescriptor).first,
           !metadata.knownIDs(for: .recipe).isEmpty {
            // An empty library with known cloud IDs means the user deleted every
            // recipe. Do not recreate the bundled samples on the next launch.
            defaults.set(true, forKey: didSeedDefaultRecipesKey)
            return
        }

        RecipeLibrary.defaults.forEach { context.insert(StoredRecipe(recipe: $0)) }
        try context.save()
        defaults.set(true, forKey: didSeedDefaultRecipesKey)
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

    /// Removes a bean and everything that only exists because of it.
    ///
    /// A recipe is written for a coffee and a brew is a record of brewing one;
    /// with the bag gone, both describe something that is not there. Deleting
    /// the bean alone used to leave its recipes pointing at a missing bag and
    /// its brews in history under a bean name nothing resolves.
    static func delete(bean: StoredBean, in context: ModelContext) throws {
        let beanID = bean.id
        let recipes = try context.fetch(FetchDescriptor<StoredRecipe>())
            .filter { $0.beanID == beanID || $0.recipe?.beanID == beanID }
        for recipe in recipes {
            try delete(recipe: recipe, in: context, save: false)
        }
        for brew in try brews(forBean: beanID, in: context) {
            context.delete(brew)
        }
        context.delete(bean)
        try context.save()
    }

    /// Removes a recipe and the brews that ran it — but never the bean, which
    /// outlives any number of attempts at brewing it.
    static func delete(recipe: StoredRecipe, in context: ModelContext, save: Bool = true) throws {
        let recipeID = recipe.id
        let related = try context.fetch(FetchDescriptor<StoredBrew>())
            .filter { $0.recipeID == recipeID || $0.entry?.recipeID == recipeID }
        for brew in related {
            context.delete(brew)
        }
        context.delete(recipe)
        if save { try context.save() }
    }

    private static func brews(forBean beanID: UUID, in context: ModelContext) throws -> [StoredBrew] {
        try context.fetch(FetchDescriptor<StoredBrew>()).filter { stored in
            if stored.beanID == beanID { return true }
            guard let entry = stored.entry else { return false }
            return entry.beanID == beanID
                || entry.beanSnapshot?.id == beanID
                || entry.recipeSnapshot?.beanID == beanID
        }
    }

    /// Drops everything past the retention limit.
    ///
    /// Called wherever history grows — after a brew is recorded, and after a
    /// sync pulls other devices' brews down — so the limit holds no matter
    /// which of them added the record. The deletions reach the cloud through
    /// the ordinary sync path, so the trim is not local-only.
    @discardableResult
    static func pruneHistory(in context: ModelContext) throws -> Int {
        let brews = try context.fetch(FetchDescriptor<StoredBrew>())
        let doomed = BrewRetention.idsToPrune(brews.map { ($0.id, $0.completedAt) })
        guard !doomed.isEmpty else { return 0 }
        for brew in brews where doomed.contains(brew.id) {
            context.delete(brew)
        }
        try context.save()
        return doomed.count
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
        try pruneHistory(in: context)
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
