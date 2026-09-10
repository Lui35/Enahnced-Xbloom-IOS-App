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
