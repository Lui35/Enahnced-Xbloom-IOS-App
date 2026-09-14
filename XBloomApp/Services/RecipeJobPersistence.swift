import Foundation
import SwiftData
import XBloomCore

/// A durable receipt prevents replay after failed acknowledgements, even if the recipe or bean is deleted.
/// The model name is retained to keep existing on-device receipt stores compatible.
@Model
final class StoredRecipeJobReceipt {
    @Attribute(.unique) var id: UUID
    var userID: UUID
    var rejection: String? = nil

    init(id: UUID, userID: UUID) {
        self.id = id
        self.userID = userID
    }
}

@MainActor
enum RecipeJobPersistence {
    /// Stores recipe and receipt in one local transaction. All devices use the request ID as
    /// the recipe ID, so concurrent collection also converges to one cloud recipe during sync.
    static func collect(
        _ row: AIJobRow, userID: UUID, in context: ModelContext,
        save: (ModelContext) throws -> Void,
        makeRecipe: (BeanProfile?) throws -> Recipe
    ) throws -> (recipe: Recipe?, rejection: String?) {
        let id = row.id
        let receipts = FetchDescriptor<StoredRecipeJobReceipt>(predicate: #Predicate { $0.id == id })
        if let receipt = try context.fetch(receipts).first(where: { $0.userID == userID }) {
            return (nil, receipt.rejection)
        }
        let recipes = FetchDescriptor<StoredRecipe>(predicate: #Predicate { $0.id == id })
        let existing = try context.fetch(recipes).first
        let receipt = StoredRecipeJobReceipt(id: id, userID: userID)
        var inserted: StoredRecipe?
        if existing == nil {
            var bean = row.context?.beanSnapshot
            if bean == nil, let beanID = row.context?.beanID {
                let query = FetchDescriptor<StoredBean>(predicate: #Predicate { $0.id == beanID })
                bean = try context.fetch(query).first?.profile
            }
            do {
                var recipe = try makeRecipe(bean)
                recipe.id = id
                inserted = StoredRecipe(recipe: recipe)
            } catch {
                // Parsing and validation are deterministic. Persist the rejection before
                // acknowledging it, so an invalid result does not restart an endless poll.
                receipt.rejection = error.localizedDescription
            }
        }
        var linkedBrew: StoredBrew?
        var previousEntry: BrewHistoryEntry?
        var previousUpdatedAt: Date?
        if inserted != nil || existing != nil, let sourceID = row.context?.sourceBrewID {
            let query = FetchDescriptor<StoredBrew>(predicate: #Predicate { $0.id == sourceID })
            linkedBrew = try context.fetch(query).first
            if var entry = linkedBrew?.entry {
                previousEntry = entry
                previousUpdatedAt = linkedBrew?.updatedAt
                entry.enhancedRecipeID = id
                linkedBrew?.update(with: entry)
            }
        }
        if let inserted { context.insert(inserted) }
        context.insert(receipt)
        do { try save(context) }
        catch {
            if let inserted { context.delete(inserted) }
            context.delete(receipt)
            if let linkedBrew, let previousEntry {
                linkedBrew.update(with: previousEntry)
                linkedBrew.updatedAt = previousUpdatedAt
            }
            throw error
        }
        return (inserted?.recipe, receipt.rejection)
    }
}

extension RecipeJobPersistence {
    /// Uses the existing receipt model for both job types; request IDs are unique across actions.
    /// The bean and receipt commit together before the server result is acknowledged.
    static func collectBean(
        _ row: AIJobRow, userID: UUID, in context: ModelContext,
        save: (ModelContext) throws -> Void, decode: () throws -> BeanPhotoResult
    ) throws -> (bean: BeanProfile?, rejection: String?) {
        let id = row.id
        let receipts = FetchDescriptor<StoredRecipeJobReceipt>(predicate: #Predicate { $0.id == id })
        if let receipt = try context.fetch(receipts).first(where: { $0.userID == userID }) {
            return (nil, receipt.rejection)
        }
        let query = FetchDescriptor<StoredBean>(predicate: #Predicate { $0.id == id })
        let receipt = StoredRecipeJobReceipt(id: id, userID: userID)
        var inserted: StoredBean?
        if try context.fetch(query).isEmpty {
            do {
                let result = try decode()
                let name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw GeminiError.invalidResponse }
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.isLenient = false
                let bean = BeanProfile(
                    id: id, name: name, roaster: result.roaster ?? "",
                    country: result.country ?? "", region: result.region ?? "",
                    producer: result.producer ?? "", species: result.species ?? "",
                    variety: result.variety ?? "", process: result.process ?? "",
                    processDetail: result.processDetail ?? "", altitudeMASL: result.altitudeMASL,
                    roastLevel: result.roastLevel ?? "",
                    roastDate: result.roastDate.flatMap { dateFormatter.date(from: $0) },
                    acidityLevel: result.acidityLevel.map { min(5, max(1, $0)) },
                    tastingNotes: result.tastingNotes ?? ""
                )
                inserted = StoredBean(profile: bean, needsVerification: true)
            } catch {
                receipt.rejection = "The label could not be read. Please try clearer photos."
            }
        }
        if let inserted { context.insert(inserted) }
        context.insert(receipt)
        do { try save(context) }
        catch {
            if let inserted { context.delete(inserted) }
            context.delete(receipt)
            throw error
        }
        return (inserted?.profile, receipt.rejection)
    }
}
