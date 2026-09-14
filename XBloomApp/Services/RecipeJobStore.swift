import Foundation
import XBloomCore

/// Account-scoped operations allow the coordinator to be tested without live services.
@MainActor
protocol RecipeJobStore: AnyObject {
    var userID: UUID? { get }
    var isAuthenticated: Bool { get }
    func openAIJobs(for userID: UUID) async throws -> [AIJobRow]
    func finishAIJob(_ requestID: UUID, for userID: UUID) async throws
    func cancelAIJob(_ requestID: UUID, for userID: UUID) async throws -> Bool
}

extension SupabaseService: RecipeJobStore {}

@MainActor
protocol RecipeJobGenerating: AnyObject {
    func startRecipeJob(
        requestID: UUID, userID: UUID, context: AIJobRow.Context, for bean: BeanProfile?,
        style: BrewStyle?, cups: Int?, goals: [String], notes: String,
        pours: Int?, beanDescription: String
    ) async throws
    func startEnhancementJob(
        requestID: UUID, userID: UUID, context: AIJobRow.Context,
        original: Recipe, bean: BeanProfile, brew: BrewHistoryEntry,
        rating: Int, feedbackTags: [String], goals: [String], notes: String
    ) async throws
    func recipeResult(from response: String) throws -> AIRecipeResult
}

extension GeminiService: RecipeJobGenerating {}

@MainActor
protocol BeanJobGenerating: AnyObject {
    func startBeanJob(requestID: UUID, userID: UUID, context: AIJobRow.Context,
                      images: [(data: Data, mimeType: String)]) async throws
    func beanResult(from response: String) throws -> BeanPhotoResult
}

extension GeminiService: BeanJobGenerating {}
