import Foundation
import SwiftData
import XBloomCore

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
           (metadata.recipeLibraryAccountID != nil || !metadata.knownIDs(for: .recipe).isEmpty) {
            // An empty library with known cloud IDs means the user deleted every
            // recipe. Do not recreate the bundled samples on the next launch.
            defaults.set(true, forKey: didSeedDefaultRecipesKey)
            return
        }

        RecipeLibrary.defaults.forEach { context.insert(StoredRecipe(recipe: $0)) }
        try context.save()
        defaults.set(true, forKey: didSeedDefaultRecipesKey)
    }

    /// Restore only after every cloud page has downloaded and decoded successfully.
    /// IDs created during the download belong to new user work and are kept for upload.
    static func restoreCloudRecipes(
        _ remote: [(recipe: Recipe, updatedAt: Date)], replacingIDs: Set<UUID>,
        userID: UUID, metadata: CloudSyncMetadata, in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        // Checkpoint any edits made during download. This synchronous main-actor block
        // has no await, so a failed replacement can roll back without losing user work.
        try context.save()
        let local = try context.fetch(FetchDescriptor<StoredRecipe>())
        let byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteIDs = Set(remote.map { $0.recipe.id })
        let previousAccount = metadata.recipeLibraryAccountID
        let previousKnown = metadata.knownRecipeIDs
        let originals = local.compactMap { stored in
            stored.recipe.map { (stored, $0, stored.updatedAt) }
        }
        for item in remote {
            if let existing = byID[item.recipe.id] {
                existing.update(with: item.recipe)
                existing.updatedAt = item.updatedAt
            } else {
                let stored = StoredRecipe(recipe: item.recipe)
                stored.updatedAt = item.updatedAt
                context.insert(stored)
            }
        }
        for stored in local where replacingIDs.contains(stored.id) && !remoteIDs.contains(stored.id) {
            context.delete(stored)
        }
        // These are the server's baseline IDs, not local removals to upload as tombstones.
        metadata.setKnownIDs(remoteIDs, for: .recipe)
        metadata.recipeLibraryAccountID = userID.uuidString
        do { try save(context) }
        catch {
            context.rollback()
            // SwiftData can retain observed property values after rollback. Restore
            // those values too, including the marker that controls the next retry.
            for (stored, recipe, date) in originals {
                stored.update(with: recipe)
                stored.updatedAt = date
            }
            metadata.recipeLibraryAccountID = previousAccount
            metadata.knownRecipeIDs = previousKnown
            throw error
        }
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

    /// Removes the bag and its active recipes. Historical snapshots, feedback and
    /// machine usage remain facts even when the library entry no longer exists.
    static func delete(bean: StoredBean, in context: ModelContext) throws {
        let beanID = bean.id
        let recipes = try context.fetch(FetchDescriptor<StoredRecipe>())
            .filter { $0.beanID == beanID || $0.recipe?.beanID == beanID }
        // Backfill older records before their last source of bean details is removed.
        preserveSnapshots(in: try brews(forBean: beanID, in: context), bean: bean.profile)
        for recipe in recipes {
            try delete(recipe: recipe, in: context, save: false)
        }
        context.delete(bean)
        try context.save()
    }

    /// Removes a recipe from the library while retaining every brew that used it.
    static func delete(recipe: StoredRecipe, in context: ModelContext, save: Bool = true) throws {
        let recipeID = recipe.id
        let related = try context.fetch(FetchDescriptor<StoredBrew>())
            .filter { $0.recipeID == recipeID || $0.entry?.recipeID == recipeID }
        var bean: BeanProfile?
        if let beanID = recipe.recipe?.beanID ?? recipe.beanID {
            let query = FetchDescriptor<StoredBean>(predicate: #Predicate { $0.id == beanID })
            bean = try context.fetch(query).first?.profile
        }
        preserveSnapshots(in: related, recipe: recipe.recipe, bean: bean)
        context.delete(recipe)
        if save { try context.save() }
    }

    private static func preserveSnapshots(
        in brews: [StoredBrew], recipe: Recipe? = nil, bean: BeanProfile? = nil
    ) {
        for brew in brews {
            guard var entry = brew.entry else { continue }
            var changed = false
            if entry.recipeSnapshot == nil, let recipe {
                entry.recipeSnapshot = recipe
                changed = true
            }
            if entry.beanSnapshot == nil, let bean {
                entry.beanSnapshot = bean
                changed = true
            }
            if changed { brew.update(with: entry) }
        }
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

    /// Keeps summaries and snapshots for maintenance and feedback; only old samples expire.
    @discardableResult
    static func compactHistory(in context: ModelContext) throws -> Int {
        let brews = try context.fetch(FetchDescriptor<StoredBrew>())
        let older = BrewRetention.idsToCompact(brews.map { ($0.id, $0.completedAt) })
        var changed = 0
        for brew in brews where older.contains(brew.id) {
            guard var entry = brew.entry, !entry.samples.isEmpty else { continue }
            entry.samples = []
            brew.update(with: entry)
            changed += 1
        }
        if changed > 0 { try context.save() }
        return changed
    }

    static func saveFeedback(
        for brew: StoredBrew, rating: Int, tags: [String], notes: String, in context: ModelContext
    ) throws {
        guard (0...5).contains(rating), let original = brew.entry else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var updated = original
        updated.rating = rating == 0 ? nil : rating
        updated.feedbackTags = tags
        updated.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDate = brew.updatedAt
        brew.update(with: updated)
        do { try context.save() }
        catch {
            brew.update(with: original)
            brew.updatedAt = originalDate
            throw error
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
        outcome: BrewOutcome = .completed,
        completedSteps: Int? = nil,
        in context: ModelContext
    ) throws {
        // Preview runs never change the real library or bean inventory.
        guard !wasSimulated else { return }
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
            wasSimulated: wasSimulated,
            outcome: outcome,
            completedSteps: outcome == .completed ? recipe.pours.count : completedSteps
        )
        context.insert(StoredBrew(entry: entry))

        if let bean, var profile = bean.profile {
            profile = Brewing.deductDose(recipe.dose, from: profile)
            bean.update(with: profile)
        }
        try context.save()
        try compactHistory(in: context)
    }

}
