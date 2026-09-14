import Foundation
import XBloomCore

/// One AI request as the backend sees it.
struct AIJobRow: Decodable, Identifiable, Equatable {
    /// What the app needs to rebuild a recipe or bean import from a response it did not wait
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
        var photoCount: Int? = nil
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

    /// Job context from older builds used Foundation's numeric reference-date encoding.
    /// PostgREST's default decoder accepts only strings, so one old snapshot could block
    /// an entire page of unrelated completed jobs. Keep this compatibility local to jobs.
    static func decodeRows(_ data: Data) throws -> [AIJobRow] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let string = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid AI job date")
        }
        return try decoder.decode([AIJobRow].self, from: data)
    }

    enum CodingKeys: String, CodingKey {
        case action, status, context, response
        case requestID = "request_id"
        case errorCode = "error_code"
        case createdAt = "created_at"
    }
}
