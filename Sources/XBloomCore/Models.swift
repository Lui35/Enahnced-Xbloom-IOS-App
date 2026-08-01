import Foundation

public enum BrewStyle: String, Codable, CaseIterable, Sendable {
    case hot
    case iced
    case cold
}

public enum PourPattern: Int, Codable, CaseIterable, Sendable {
    case center = 0
    case circular = 1
    case spiral = 2
}

public enum GrinderRPM: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case rpm60 = 60
    case rpm70 = 70
    case rpm80 = 80
    case rpm90 = 90
    case rpm100 = 100
    case rpm110 = 110
    case rpm120 = 120
}

public struct PourStep: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var volume: Int
    public var temperature: Int
    public var flowRate: Double
    public var pauseBefore: Int
    public var pauseAfter: Int
    public var pattern: PourPattern
    public var agitationBefore: Bool
    public var agitationAfter: Bool

    public init(
        id: UUID = UUID(),
        volume: Int,
        temperature: Int,
        flowRate: Double = 3,
        pauseBefore: Int = 0,
        pauseAfter: Int = 0,
        pattern: PourPattern = .spiral,
        agitationBefore: Bool = false,
        agitationAfter: Bool = false
    ) {
        self.id = id
        self.volume = volume
        self.temperature = temperature
        self.flowRate = flowRate
        self.pauseBefore = pauseBefore
        self.pauseAfter = pauseAfter
        self.pattern = pattern
        self.agitationBefore = agitationBefore
        self.agitationAfter = agitationAfter
    }
}

public struct Recipe: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var roaster: String
    public var origin: String
    public var grindSize: Int
    public var rpm: GrinderRPM
    public var dose: Double
    public var useGrinder: Bool
    public var brewStyle: BrewStyle
    public var iceGrams: Int
    public var beanID: UUID?
    public var generatedByAI: Bool
    public var servings: Int?
    public var aiDescription: String?
    public var parentRecipeID: UUID?
    public var sourceBrewID: UUID?
    public var pours: [PourStep]

    public init(
        id: UUID = UUID(),
        name: String,
        roaster: String = "",
        origin: String = "",
        grindSize: Int = 50,
        rpm: GrinderRPM = .rpm80,
        dose: Double = 18,
        useGrinder: Bool = true,
        brewStyle: BrewStyle = .hot,
        iceGrams: Int = 0,
        beanID: UUID? = nil,
        generatedByAI: Bool = false,
        servings: Int? = nil,
        aiDescription: String? = nil,
        parentRecipeID: UUID? = nil,
        sourceBrewID: UUID? = nil,
        pours: [PourStep]
    ) {
        self.id = id
        self.name = name
        self.roaster = roaster
        self.origin = origin
        self.grindSize = grindSize
        self.rpm = rpm
        self.dose = dose
        self.useGrinder = useGrinder
        self.brewStyle = brewStyle
        self.iceGrams = iceGrams
        self.beanID = beanID
        self.generatedByAI = generatedByAI
        self.servings = servings
        self.aiDescription = aiDescription
        self.parentRecipeID = parentRecipeID
        self.sourceBrewID = sourceBrewID
        self.pours = pours
    }

    public var totalWater: Int {
        pours.reduce(0) { $0 + $1.volume }
    }

    public var ratio: Double {
        dose > 0 ? Double(totalWater) / dose : 0
    }
}

/// A portable, versioned snapshot of a complete recipe library. Keeping the
/// envelope in XBloomCore lets future app versions migrate older exports
/// without changing the on-device SwiftData model.
public struct RecipeLibraryArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var recipes: [Recipe]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date = Date(),
        recipes: [Recipe]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.recipes = recipes
    }
}

public struct BeanProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var roaster: String
    public var country: String
    public var region: String
    public var producer: String
    public var species: String
    public var variety: String
    public var process: String
    public var processDetail: String
    public var altitudeMASL: Int?
    public var roastLevel: String
    public var roastDate: Date?
    public var acidityLevel: Int?
    public var tastingNotes: String
    public var desiredCup: String
    public var initialWeightGrams: Double
    public var remainingWeightGrams: Double
    public var archived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        roaster: String = "",
        country: String = "",
        region: String = "",
        producer: String = "",
        species: String = "Arabica",
        variety: String = "",
        process: String = "Washed",
        processDetail: String = "",
        altitudeMASL: Int? = nil,
        roastLevel: String = "Medium-light",
        roastDate: Date? = nil,
        acidityLevel: Int? = nil,
        tastingNotes: String = "",
        desiredCup: String = "",
        initialWeightGrams: Double = 250,
        remainingWeightGrams: Double = 250,
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.roaster = roaster
        self.country = country
        self.region = region
        self.producer = producer
        self.species = species
        self.variety = variety
        self.process = process
        self.processDetail = processDetail
        self.altitudeMASL = altitudeMASL
        self.roastLevel = roastLevel
        self.roastDate = roastDate
        self.acidityLevel = acidityLevel
        self.tastingNotes = tastingNotes
        self.desiredCup = desiredCup
        self.initialWeightGrams = initialWeightGrams
        self.remainingWeightGrams = remainingWeightGrams
        self.archived = archived
    }
}

public enum RecipeFlavorGoal: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case balanced = "Balanced"
    case sweetness = "More sweetness"
    case roundness = "Round & smooth"
    case clarity = "Higher clarity"
    case floral = "More floral"
    case juicy = "Juicy"
    case fullBody = "Full body"
    case chocolate = "Chocolate notes"
    case brightAcidity = "Bright acidity"
    case lowAcidity = "Low acidity"
    case teaLike = "Tea-like"
    case cleanFinish = "Clean finish"

    public var id: String { rawValue }

    public var conflicts: Set<RecipeFlavorGoal> {
        switch self {
        case .brightAcidity: [.lowAcidity]
        case .lowAcidity: [.brightAcidity]
        case .teaLike: [.fullBody]
        case .fullBody: [.teaLike]
        default: []
        }
    }

    public static func toggling(
        _ goal: RecipeFlavorGoal,
        in selection: Set<RecipeFlavorGoal>
    ) -> Set<RecipeFlavorGoal> {
        var updated = selection
        if updated.contains(goal) {
            updated.remove(goal)
        } else {
            updated.subtract(goal.conflicts)
            updated.insert(goal)
        }
        return updated
    }
}

public struct BrewSample: Codable, Equatable, Sendable {
    public var elapsed: TimeInterval
    public var water: Double
    public var coffeeWeight: Double
    public var temperature: Double?

    public init(elapsed: TimeInterval, water: Double, coffeeWeight: Double, temperature: Double? = nil) {
        self.elapsed = elapsed
        self.water = water
        self.coffeeWeight = coffeeWeight
        self.temperature = temperature
    }
}

public struct BrewHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var recipeID: UUID?
    public var recipeName: String
    public var beanID: UUID?
    public var beanName: String?
    public var completedAt: Date
    public var duration: TimeInterval
    public var water: Double
    public var coffeeWeight: Double
    public var steps: Int
    public var rating: Int?
    public var notes: String
    public var samples: [BrewSample]
    public var recipeSnapshot: Recipe?
    public var beanSnapshot: BeanProfile?
    public var feedbackTags: [String]?
    public var enhancementGoals: [String]?
    public var enhancedRecipeID: UUID?
    /// `nil` for history created before simulation records were introduced.
    public var wasSimulated: Bool?

    public init(
        id: UUID = UUID(),
        recipeID: UUID?,
        recipeName: String,
        beanID: UUID?,
        beanName: String?,
        completedAt: Date = Date(),
        duration: TimeInterval,
        water: Double,
        coffeeWeight: Double,
        steps: Int,
        rating: Int? = nil,
        notes: String = "",
        samples: [BrewSample] = [],
        recipeSnapshot: Recipe? = nil,
        beanSnapshot: BeanProfile? = nil,
        feedbackTags: [String]? = nil,
        enhancementGoals: [String]? = nil,
        enhancedRecipeID: UUID? = nil,
        wasSimulated: Bool = false
    ) {
        self.id = id
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.beanID = beanID
        self.beanName = beanName
        self.completedAt = completedAt
        self.duration = duration
        self.water = water
        self.coffeeWeight = coffeeWeight
        self.steps = steps
        self.rating = rating
        self.notes = notes
        self.samples = samples
        self.recipeSnapshot = recipeSnapshot
        self.beanSnapshot = beanSnapshot
        self.feedbackTags = feedbackTags
        self.enhancementGoals = enhancementGoals
        self.enhancedRecipeID = enhancedRecipeID
        self.wasSimulated = wasSimulated
    }
}
