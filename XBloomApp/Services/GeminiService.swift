import Foundation
import Observation
import XBloomCore

@MainActor
@Observable
final class GeminiService {
    private let cloud: SupabaseService

    private static let professionalV60Brief = """
    Work as a competition-aware specialty-coffee barista dialing in a V60-style
    percolation recipe, not as a generic recipe generator. There is no universally
    correct pour count. Treat pour architecture as an extraction decision, never
    as a template to fill.

    First infer an extraction strategy from the supplied bean: roast development,
    process, likely density/solubility, origin/elevation when present, tasting notes,
    acidity, and the requested cup goals. If any of these are missing, infer a
    conservative default from typical practice for the stated origin, process, or
    roast level, and briefly flag the assumption in rationale rather than treating
    the gap as license to invent specifics.

    Design the pour sequence and brew ratio (dose, total water, resulting yield)
    from first principles as one decision, not two. The machine supports 1-8 total
    pour steps; every count in that range is equally valid when justified. Do not
    aim for three, four, or any other count, and do not add or remove steps merely
    for variety. A single continuous program, a bloom plus a main pour, several
    staged pours, or a pulse-based method may all be correct. Choose solely from
    what best expresses this bean and the requested cup, then identify the
    resulting approach in method_name.

    Use a bloom when it benefits degassing and even saturation; its volume and rest
    should respond to freshness, roast, process, dose, and method rather than being
    mandatory. When used, a bloom around 2-4 times the coffee dose and a 25-45 second
    rest are reasonable starting references, not fixed rules. Select grind,
    temperature, pulse size, flow, pattern, pauses, and agitation as one coherent
    system. Prefer minimal, purposeful agitation: enough to wet evenly and flatten
    the bed, but avoid repeated agitation for highly soluble, darker, natural,
    anaerobic, or heavily fermented coffees when it risks harshness. Use more
    extraction energy only when the bean and desired cup justify it. Keep this
    recipe consistent with specialty hot-brew filter-coffee practice (as opposed to
    cold brew or immersion methods) while adapting rather than blindly copying a
    famous recipe.

    method_name and rationale must explain why this architecture fits this exact
    bean and cup goal. In 2-4 sentences, the rationale must mention the selected
    pour count, bloom, grind/temperature direction, and the intended sensory result.

    These two cases illustrate the reasoning style expected, not templates to
    match against incoming beans:

    - A washed, high-elevation Ethiopian, light roast, floral/bergamot notes, high
        acidity: dense, less-soluble bean with delicate, volatile aromatics favors a
        controlled multi-stage pour (bloom plus several measured pulses) at a
        higher-end filter temperature, minimal agitation, to extract fully without
        dulling clarity.

    - A natural Brazilian, darker roast, low elevation, chocolate/nutty notes, low
        acidity: highly soluble, fragile-toward-bitterness bean favors a short
        architecture (bloom plus one main pour) at a lower-end filter temperature,
        minimal agitation, to protect sweetness and avoid harsh, over-extracted
        notes.

    Let the bean in front of you, not these examples, determine the pour count.
    """

    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "geminiModel") }
    }

    static let defaultModel = "gemini-3.6-flash"

    /// The names the Edge Function will accept. It matches `^gemini-…$` and
    /// forwards the name to Google, so anything else fails at the server with
    /// nothing the app can explain — better to refuse it while it is being
    /// typed.
    static func isValidModelName(_ name: String) -> Bool {
        name.range(of: "^gemini-[a-z0-9.-]{1,64}$", options: .regularExpression) != nil
    }

    init(cloud: SupabaseService) {
        self.cloud = cloud
        model = UserDefaults.standard.string(forKey: "geminiModel") ?? Self.defaultModel
    }

    var hasAPIKey: Bool {
        cloud.isAuthenticated
    }

    func testConnection() async throws {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "Reply with the single word OK."]]]],
            "generationConfig": ["temperature": 0],
        ]
        _ = try await request(body: body, action: "testConnection")
    }

    func importBean(images: [(data: Data, mimeType: String)]) async throws -> BeanPhotoResult {
        guard !images.isEmpty else { throw GeminiError.missingImages }
        guard images.reduce(0, { $0 + $1.data.count }) <= 18_000_000 else {
            throw GeminiError.imagesTooLarge
        }
        var parts: [[String: Any]] = [[
            "text": """
            Read this specialty-coffee package label and extract only facts visible on it.
            Do not guess missing values. Use null when a field is absent or uncertain.
            For name, use the coffee/product name, not the roaster name. Preserve named
            varieties and processing terms. Put co-fermentation, infusion, honey type,
            or decaffeination details in process_detail. Add a 0-1 confidence score for
            every non-null extracted field in confidence. If the package explicitly
            gives an acidity scale, normalize it to 1-5; otherwise use null. Return only JSON.
            """
        ]]
        parts.append(contentsOf: images.map {
            ["inlineData": ["mimeType": $0.mimeType, "data": $0.data.base64EncodedString()]]
        })
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": BeanPhotoResult.schema,
            ],
        ]
        return try decodeModelResponse(
            try await request(body: body, action: "importBean"),
            as: BeanPhotoResult.self
        )
    }

    /// - Parameters:
    ///   - bean: The coffee, when there is one in the library. Without it the
    ///     model has nothing to reason from, so `beanDescription` carries
    ///     whatever the user could say about what is in the hopper.
    ///   - pours: A pour count the user insisted on. Nil leaves the
    ///     architecture to the model, which is what the brief is written for.
    func generateRecipe(
        for bean: BeanProfile?,
        style: BrewStyle? = .hot,
        cups: Int? = 1,
        goals: [String] = [],
        notes: String = "",
        pours: Int? = nil,
        beanDescription: String = ""
    ) async throws -> AIRecipeResult {
        let profileJSON: String
        if let bean {
            profileJSON = String(decoding: try JSONEncoder().encode(bean), as: UTF8.self)
        } else {
            let described = beanDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            profileJSON = described.isEmpty
                ? "No bean details were supplied. Design for a typical washed, "
                    + "medium-light filter coffee and say so in the rationale."
                : "No structured bean profile is available. The user describes "
                    + "the coffee as: \(described)"
        }
        let styleRequest = style.map { "\($0.rawValue) pour-over" }
            ?? "hot or iced pour-over, whichever best suits the bean"
        let servingRequest = cups.map { "\($0) cup(s)" }
            ?? "1-2 cups, choosing the serving count that produces the most coherent recipe"
        let pourRequest = pours.map {
            "The user has asked for exactly \($0) pour step(s). Use that count and "
                + "make it work for this coffee, rather than choosing your own."
        } ?? ""
        let selectedGoals = goals.isEmpty
            ? "Analyze the bean and choose the flavor direction that best showcases it."
            : goals.joined(separator: ", ")
        let prompt = """
        \(BrewingReference.text)

        You are an expert specialty-coffee recipe designer for an xBloom Studio.
        Reason from the reference above; do not quote it or name its sections.
        Create one practical \(styleRequest) recipe for \(servingRequest) from the bean profile below.
        The user's simultaneous cup goals are: \(selectedGoals)
        Additional user note: \(notes.isEmpty ? "None." : notes)
        \(pourRequest)
        Treat every selected goal as intentional and optimize them together. Do not discard
        one goal merely because another creates a tradeoff; choose a sensible balance and
        explain that balance in the rationale.
        \(Self.professionalV60Brief)
        Return only the requested JSON schema. Respect every numeric schema limit.
        Choose a coherent dose and total water. Use roughly 180-260 ml per hot cup,
        or 100-220 ml machine water plus 60-180 g ice per iced cup. The ratio uses
        machine-poured water only: normally 1:14.5-1:18.5 for hot and 1:7.5-1:15
        for iced concentrate. Total machine water must not
        exceed 500 ml and each pour must not exceed 240 ml.
        This is pour-over. Grind must be 31-55. Temperatures are Celsius and flow
        is ml/s. Keep the full program roughly 1:45-4:00, including pauses.
        Bean profile: \(profileJSON)
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.35,
                "responseMimeType": "application/json",
                "responseJsonSchema": AIRecipeResult.schema,
            ],
        ]
        return try decodeModelResponse(
            try await request(body: body, action: "generateRecipe"),
            as: AIRecipeResult.self
        )
    }

    func enhanceRecipe(
        original: Recipe,
        bean: BeanProfile,
        brew: BrewHistoryEntry,
        rating: Int,
        feedbackTags: [String],
        goals: [String],
        notes: String
    ) async throws -> AIRecipeResult {
        let context: [String: Any] = [
            "rating_out_of_5": min(5, max(1, rating)),
            "quick_feedback": feedbackTags,
            "desired_cup_goals": goals,
            "user_notes": notes,
        ]
        let brewResult: [String: Any] = [
            "duration_seconds": brew.duration,
            "machine_water_ml": brew.water,
            "scale_yield_grams": brew.coffeeWeight,
            "completed_pour_steps": brew.steps,
        ]
        let feedbackJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: context),
            as: UTF8.self
        )
        let brewResultJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: brewResult),
            as: UTF8.self
        )
        let recipeJSON = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        let beanJSON = String(decoding: try JSONEncoder().encode(bean), as: UTF8.self)
        let style = original.brewStyle == .iced ? "iced" : "hot"
        let cups = min(3, max(1, original.servings ?? 1))

        let prompt = """
        \(BrewingReference.text)

        You are improving an xBloom Studio pour-over recipe after a real brew.
        Diagnose from the reference above; do not quote it or name its sections.
        The original recipe, exact bean, brew style, and serving count are supplied below.
        Create a NEW improved recipe; do not merely rename or repeat the old one.

        Preserve these user-controlled requirements exactly:
        - brew_style: \(style)
        - servings: \(cups)
        - bean identity: unchanged

        \(Self.professionalV60Brief)

        Diagnose the feedback using coffee-extraction principles. Change only parameters
        that plausibly address the reported cup: dose, water, grind, RPM, temperature,
        pour count, pour volumes, flow, pauses, patterns, or agitation. Re-evaluate the
        complete pour architecture instead of automatically preserving the original count.
        Keep every value inside the
        response schema and xBloom safety limits. The rationale must clearly summarize
        what changed and why in relation to the rating, feedback, and every selected
        desired-cup goal. Treat selected goals as simultaneous requirements; when they
        create a tradeoff, balance them rather than silently dropping one. Give the new
        recipe a concise name distinct from "\(original.name)".

        Original recipe JSON:
        \(recipeJSON)

        Bean JSON:
        \(beanJSON)

        Measured brew result JSON:
        \(brewResultJSON)

        Brew feedback JSON:
        \(feedbackJSON)
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.35,
                "responseMimeType": "application/json",
                "responseJsonSchema": AIRecipeResult.schema,
            ],
        ]
        return try decodeModelResponse(
            try await request(body: body, action: "enhanceRecipe"),
            as: AIRecipeResult.self
        )
    }

    private func request(body: [String: Any], action: String) async throws -> Data {
        guard cloud.isAuthenticated else {
            throw GeminiError.missingAPIKey
        }
        return try await cloud.invokeAI(action: action, model: model, body: body)
    }

    private func decodeModelResponse<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
        guard let text = envelope.candidates.first?.content.parts.first?.text else {
            throw GeminiError.invalidResponse
        }
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let modelData = cleaned.data(using: .utf8) else { throw GeminiError.invalidResponse }
        return try JSONDecoder().decode(type, from: modelData)
    }
}

struct BeanPhotoResult: Codable {
    var name: String
    var roaster: String?
    var country: String?
    var region: String?
    var producer: String?
    var species: String?
    var variety: String?
    var process: String?
    var processDetail: String?
    var altitudeMASL: Int?
    var roastLevel: String?
    var roastDate: String?
    var tastingNotes: String?
    var acidityLevel: Int?
    var confidence: [String: Double]

    enum CodingKeys: String, CodingKey {
        case name, roaster, country, region, producer, species, variety, process
        case processDetail = "process_detail"
        case altitudeMASL = "altitude_masl"
        case roastLevel = "roast_level"
        case roastDate = "roast_date"
        case tastingNotes = "tasting_notes"
        case acidityLevel = "acidity_level"
        case confidence
    }

    nonisolated(unsafe) static let schema: [String: Any] = [
        "type": "object",
        "required": ["name", "confidence"],
        "properties": [
            "name": ["type": "string"],
            "roaster": nullableString,
            "country": nullableString,
            "region": nullableString,
            "producer": nullableString,
            "species": nullableString,
            "variety": nullableString,
            "process": nullableString,
            "process_detail": nullableString,
            "altitude_masl": ["type": ["integer", "null"]],
            "roast_level": nullableString,
            "roast_date": nullableString,
            "tasting_notes": nullableString,
            "acidity_level": ["type": ["integer", "null"], "minimum": 1, "maximum": 5],
            "confidence": [
                "type": "object",
                "additionalProperties": ["type": "number", "minimum": 0, "maximum": 1],
            ],
        ],
    ]

    nonisolated(unsafe) private static let nullableString: [String: Any] = ["type": ["string", "null"]]
}

struct AIRecipeResult: Codable {
    struct Pour: Codable {
        var volume: Int
        var temp: Int
        var flow: Double
        var pauseAfter: Int
        var pattern: String
        var agitationBefore: Bool
        var agitationAfter: Bool
    }

    var name: String
    var methodName: String
    var rationale: String
    var brewStyle: String
    var servings: Int
    var iceGrams: Int
    var grind: Int
    var rpm: Int
    var dose: Double
    var pours: [Pour]

    enum CodingKeys: String, CodingKey {
        case name, rationale, servings, grind, rpm, dose, pours
        case methodName = "method_name"
        case brewStyle = "brew_style"
        case iceGrams = "ice_grams"
    }

    func recipe(bean: BeanProfile?, cups: Int? = 1, requestedStyle: BrewStyle? = nil) throws -> Recipe {
        let steps = pours.map {
            PourStep(
                volume: min(240, max(0, $0.volume)),
                temperature: min(96, max(80, $0.temp)),
                flowRate: min(3.5, max(3, $0.flow)),
                pauseAfter: min(60, max(0, $0.pauseAfter)),
                pattern: PourPattern(rawValue: ["center", "circular", "spiral"].firstIndex(of: $0.pattern) ?? 0) ?? .center,
                agitationBefore: $0.agitationBefore,
                agitationAfter: $0.agitationAfter
            )
        }
        let value = Recipe(
            name: String(name.prefix(80)),
            roaster: bean?.roaster ?? "",
            origin: [bean?.country, bean?.process]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            grindSize: min(55, max(31, grind)),
            rpm: GrinderRPM(rawValue: rpm) ?? .rpm80,
            dose: min(30, max(5, dose)),
            brewStyle: requestedStyle ?? BrewStyle(rawValue: brewStyle) ?? .hot,
            iceGrams: max(0, iceGrams),
            beanID: bean?.id,
            generatedByAI: true,
            servings: min(2, max(1, cups ?? servings)),
            aiDescription: "\(methodName): \(rationale)",
            pours: Array(steps.prefix(8))
        )
        try RecipeValidator.requireSafe(value)
        return value
    }

    nonisolated(unsafe) static let schema: [String: Any] = [
        "type": "object",
        "required": ["name", "method_name", "rationale", "brew_style", "servings", "ice_grams", "grind", "rpm", "dose", "pours"],
        "properties": [
            "name": ["type": "string"],
            "method_name": ["type": "string"],
            "rationale": ["type": "string"],
            "brew_style": ["type": "string", "enum": ["hot", "iced"]],
            "servings": ["type": "integer", "minimum": 1, "maximum": 3],
            "ice_grams": ["type": "integer", "minimum": 0, "maximum": 500],
            "grind": ["type": "integer", "minimum": 31, "maximum": 55],
            "rpm": ["type": "integer", "enum": [60, 70, 80, 90, 100, 110, 120]],
            "dose": ["type": "number", "minimum": 5, "maximum": 30],
            "pours": [
                "type": "array",
                "minItems": 1,
                "maxItems": 8,
                "items": [
                    "type": "object",
                    "required": ["volume", "temp", "flow", "pauseAfter", "pattern", "agitationBefore", "agitationAfter"],
                    "properties": [
                        "volume": ["type": "integer", "minimum": 0, "maximum": 240],
                        "temp": ["type": "integer", "minimum": 80, "maximum": 96],
                        "flow": ["type": "number", "minimum": 3, "maximum": 3.5],
                        "pauseAfter": ["type": "integer", "minimum": 0, "maximum": 60],
                        "pattern": ["type": "string", "enum": ["center", "circular", "spiral"]],
                        "agitationBefore": ["type": "boolean"],
                        "agitationAfter": ["type": "boolean"],
                    ],
                ] as [String: Any],
            ],
        ],
    ]
}

private struct GeminiEnvelope: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]
        }
        let content: Content
    }
    let candidates: [Candidate]
}

private struct GeminiAPIError: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case missingImages
    case imagesTooLarge
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Sign in to Supabase in Settings to use Gemini."
        case .missingImages: "Add at least one clear photo of the coffee bag."
        case .imagesTooLarge: "The selected photos are too large. Choose smaller images and try again."
        case .invalidResponse: "Gemini returned an invalid response."
        case let .api(message): message
        }
    }
}
