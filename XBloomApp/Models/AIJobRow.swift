import Foundation
import XBloomCore

/// One AI request as the backend sees it.
struct AIJobRow: Decodable, Identifiable, Equatable {
    /// What the app needs to rebuild a recipe from a response it did not wait
    /// for. Written by the app, stored untouched, read back a launch later.
    struct Context: Codable, Equatable {
        var beanID: UUID?
        var beanName: String
        var style: String
        var cups: Int
        var useGrinder: Bool
        var parentRecipeID: UUID? = nil
        var sourceBrewID: UUID? = nil
        var beanSnapshot: BeanProfile? = nil
    }

    let requestID: UUID
    let action: String
    let status: String
    let errorCode: String?
    let context: Context?
    /// Gemini's own response body, exactly as it was returned, so the app
    /// decodes and validates it with the same code it uses when it waits.
    let response: String?
    let createdAt: Date

    var id: UUID { requestID }

    enum CodingKeys: String, CodingKey {
        case action, status, context, response
        case requestID = "request_id"
        case errorCode = "error_code"
        case createdAt = "created_at"
    }
}
