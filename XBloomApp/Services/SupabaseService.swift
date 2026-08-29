import Foundation
import Observation
import Supabase
import SwiftData
import XBloomCore

@MainActor
@Observable
final class SupabaseService {
    static let projectURL = URL(string: "https://cndmrczfnwztrmafxhmd.supabase.co")!
    static let publishableKey = "sb_publishable_ULORWw52UGOHx2KEgUwK0w_HBZ_ga7x"
    static let authCallbackURL = URL(string: "xbloom://login-callback")!

    let client: SupabaseClient
    private(set) var userID: UUID?
    private(set) var email: String?
    private(set) var hasValidSession = false
    private(set) var isSyncing = false
    private(set) var isApplyingCloudChanges = false
    private(set) var lastSyncAt: Date?
    private(set) var statusMessage: String?
    private var automaticSyncTask: Task<Void, Never>?

    var isAuthenticated: Bool { hasValidSession && userID != nil }

    init() {
        client = SupabaseClient(
            supabaseURL: Self.projectURL,
            supabaseKey: Self.publishableKey
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await (_, session) in client.auth.authStateChanges {
                apply(session: session)
            }
        }
    }

    func refreshSession() async {
        do {
            let session = try await client.auth.session
            apply(session: session)
        } catch {
            apply(session: nil)
        }
    }

    func signUp(email: String, password: String) async throws {
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            redirectTo: Self.authCallbackURL
        )
        if let session = response.session {
            apply(session: session)
            statusMessage = "Cloud account connected."
        } else {
            apply(session: nil)
            statusMessage = "Account created. Confirm the email, then return here and sign in."
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await client.auth.signIn(email: email, password: password)
        apply(session: session)
        statusMessage = "Cloud account connected."
    }

    func signOut() async throws {
        automaticSyncTask?.cancel()
        try await client.auth.signOut()
        apply(session: nil)
        statusMessage = "Signed out. Your on-device library is unchanged."
    }

    func scheduleAutomaticSync(in context: ModelContext) {
        guard isAuthenticated, !isApplyingCloudChanges else { return }
        automaticSyncTask?.cancel()
        automaticSyncTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self else { return }
                while isSyncing {
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard isAuthenticated else { return }
                _ = try await sync(in: context)
            } catch is CancellationError {
                // A newer local save replaced this pending sync.
            } catch {
                // sync(in:) exposes the failure through statusMessage.
            }
        }
    }

    func handleOpenURL(_ url: URL) async {
        do {
            let session = try await client.auth.session(from: url)
            apply(session: session)
            statusMessage = "Email confirmed. Cloud account connected."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func invokeAI(action: String, model: String, body: [String: Any]) async throws -> Data {
        let session = try await requireSession()
        var request = URLRequest(url: Self.projectURL.appending(path: "functions/v1/coffee-ai"))
        request.httpMethod = "POST"
        request.timeoutInterval = 85
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": action,
            "model": model,
            "body": body,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(CloudFunctionError.self, from: data).error)
            throw CloudError.function(message ?? "Cloud AI returned HTTP \(http.statusCode).")
        }
        return data
    }

    @discardableResult
    func sync(in context: ModelContext) async throws -> CloudSyncSummary {
        guard !isSyncing else { throw CloudError.syncAlreadyRunning }
        let session = try await requireSession()
        let userID = session.user.id
        let database = client.schema("public").setAuth(session.accessToken)
        isSyncing = true
        statusMessage = "Syncing your library…"
        defer { isSyncing = false }

        do {
            let metadata = try syncMetadata(for: userID, in: context)
            let summary = try await performSync(
                userID: userID,
                metadata: metadata,
                context: context,
                database: database
            )
            let now = Date()
            try applyCloudChanges {
                metadata.lastSyncedAt = now
                lastSyncAt = now
                try context.save()
            }

            let profile = CloudProfileRow(
                userID: userID,
                initialSyncCompletedAt: now,
                lastClientSyncAt: now
            )
            try await database.from("profiles")
                .upsert(profile, onConflict: "user_id")
                .execute()
            statusMessage = "Synced \(summary.total) records."
            return summary
        } catch {
            statusMessage = "Sync failed: \(error.localizedDescription)"
            throw error
        }
    }

    private func performSync(
        userID: UUID,
        metadata: CloudSyncMetadata,
        context: ModelContext,
        database: PostgrestClient
    ) async throws -> CloudSyncSummary {
        var beans = try context.fetch(FetchDescriptor<StoredBean>())
        var recipes = try context.fetch(FetchDescriptor<StoredRecipe>())
        var brews = try context.fetch(FetchDescriptor<StoredBrew>())
        var maintenance = try context.fetch(FetchDescriptor<StoredMaintenanceEvent>())

        let remoteBeans: [CloudBeanRow] = try await database.from("beans")
            .select("user_id,id,name,roaster,remaining_weight_grams,archived,payload_json,client_updated_at,deleted_at")
            .eq("user_id", value: userID.uuidString)
            .execute().value
        let remoteRecipes: [CloudRecipeRow] = try await database.from("recipes")
            .select("user_id,id,name,roaster,origin,brew_style,generated_by_ai,servings,bean_id,payload_json,client_updated_at,deleted_at")
            .eq("user_id", value: userID.uuidString)
            .execute().value
        let remoteBrews: [CloudBrewRow] = try await database.from("brews")
            .select("user_id,id,recipe_id,bean_id,recipe_name,bean_name,completed_at,duration_seconds,rating,brew_style,generated_by_ai,was_simulated,servings,water_ml,coffee_weight_grams,step_count,payload_json,client_updated_at,deleted_at")
            .eq("user_id", value: userID.uuidString)
            .execute().value
        let remoteMaintenance: [CloudMaintenanceRow] = try await database.from("maintenance_events")
            .select("user_id,id,task,performed_at,note,client_updated_at,deleted_at")
            .eq("user_id", value: userID.uuidString)
            .execute().value
        try applyCloudChanges {
            merge(remoteBeans, into: &beans, known: metadata.knownIDs(for: .bean), context: context)
            merge(remoteRecipes, into: &recipes, known: metadata.knownIDs(for: .recipe), context: context)
            merge(remoteBrews, into: &brews, known: metadata.knownIDs(for: .brew), context: context)
            merge(
                remoteMaintenance,
                into: &maintenance,
                known: metadata.knownIDs(for: .maintenance),
                context: context
            )
            try context.save()
        }

        beans = try context.fetch(FetchDescriptor<StoredBean>())
        recipes = try context.fetch(FetchDescriptor<StoredRecipe>())
        brews = try context.fetch(FetchDescriptor<StoredBrew>())
        maintenance = try context.fetch(FetchDescriptor<StoredMaintenanceEvent>())

        try await pushDeletions(
            table: "maintenance_events",
            userID: userID,
            deletedIDs: metadata.knownIDs(for: .maintenance).subtracting(maintenance.map(\.id)),
            database: database
        )
        try await pushDeletions(
            table: "brews",
            userID: userID,
            deletedIDs: metadata.knownIDs(for: .brew).subtracting(brews.map(\.id)),
            database: database
        )
        try await pushDeletions(
            table: "recipes",
            userID: userID,
            deletedIDs: metadata.knownIDs(for: .recipe).subtracting(recipes.map(\.id)),
            database: database
        )
        try await pushDeletions(
            table: "beans",
            userID: userID,
            deletedIDs: metadata.knownIDs(for: .bean).subtracting(beans.map(\.id)),
            database: database
        )

        let beanIDs = Set(beans.map(\.id))
        let recipeIDs = Set(recipes.map(\.id))
        if !beans.isEmpty {
            try await database.from("beans")
                .upsert(beans.map { CloudBeanRow(userID: userID, stored: $0) }, onConflict: "user_id,id")
                .execute()
        }
        if !recipes.isEmpty {
            try await database.from("recipes")
                .upsert(
                    recipes.map { CloudRecipeRow(userID: userID, stored: $0, validBeanIDs: beanIDs) },
                    onConflict: "user_id,id"
                )
                .execute()
        }
        if !brews.isEmpty {
            try await database.from("brews")
                .upsert(
                    brews.map {
                        CloudBrewRow(
                            userID: userID,
                            stored: $0,
                            validBeanIDs: beanIDs,
                            validRecipeIDs: recipeIDs
                        )
                    },
                    onConflict: "user_id,id"
                )
                .execute()
        }

        if !maintenance.isEmpty {
            try await database.from("maintenance_events")
                .upsert(
                    maintenance.map { CloudMaintenanceRow(userID: userID, stored: $0) },
                    onConflict: "user_id,id"
                )
                .execute()
        }

        metadata.setKnownIDs(Set(beans.map(\.id)), for: .bean)
        metadata.setKnownIDs(Set(recipes.map(\.id)), for: .recipe)
        metadata.setKnownIDs(Set(brews.map(\.id)), for: .brew)
        metadata.setKnownIDs(Set(maintenance.map(\.id)), for: .maintenance)
        return CloudSyncSummary(
            beans: beans.count,
            recipes: recipes.count,
            brews: brews.count,
            maintenance: maintenance.count
        )
    }

    private func syncMetadata(for userID: UUID, in context: ModelContext) throws -> CloudSyncMetadata {
        var descriptor = FetchDescriptor<CloudSyncMetadata>(
            predicate: #Predicate { $0.id == "cloud-sync" }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            if existing.userID != userID.uuidString {
                existing.userID = userID.uuidString
                existing.knownBeanIDs = Data()
                existing.knownRecipeIDs = Data()
                existing.knownBrewIDs = Data()
                existing.lastSyncedAt = nil
            }
            return existing
        }
        let value = CloudSyncMetadata(userID: userID)
        context.insert(value)
        return value
    }

    private func pushDeletions(
        table: String,
        userID: UUID,
        deletedIDs: Set<UUID>,
        database: PostgrestClient
    ) async throws {
        let tombstone = CloudTombstone(deletedAt: Date(), clientUpdatedAt: Date())
        for id in deletedIDs {
            try await database.from(table)
                .update(tombstone)
                .eq("user_id", value: userID.uuidString)
                .eq("id", value: id.uuidString)
                .execute()
        }
    }

    private func requireSession() async throws -> Session {
        do {
            let session = try await client.auth.session
            apply(session: session)
            return session
        } catch {
            apply(session: nil)
            statusMessage = "Your Supabase session has expired. Sign in again to continue."
            throw CloudError.notSignedIn
        }
    }

    private func apply(session: Session?) {
        userID = session?.user.id
        email = session?.user.email
        hasValidSession = session != nil
        if session == nil {
            automaticSyncTask?.cancel()
        }
    }

    private func applyCloudChanges(_ changes: () throws -> Void) rethrows {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        try changes()
    }

    /// A service performed is a fact with a date on it: there is nothing to
    /// update, only rows to add and rows the user took back.
    private func merge(
        _ remote: [CloudMaintenanceRow],
        into local: inout [StoredMaintenanceEvent],
        known: Set<UUID>,
        context: ModelContext
    ) {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for row in remote {
            if row.deletedAt != nil {
                if let stored = byID.removeValue(forKey: row.id) {
                    context.delete(stored)
                }
            } else if let stored = byID[row.id] {
                if row.clientUpdatedAt > stored.updatedAt {
                    stored.task = row.task
                    stored.performedAt = row.performedAt
                    stored.note = row.note
                    stored.updatedAt = row.clientUpdatedAt
                }
            } else if !known.contains(row.id), let task = MaintenanceTask(rawValue: row.task) {
                let stored = StoredMaintenanceEvent(
                    id: row.id,
                    task: task,
                    performedAt: row.performedAt,
                    note: row.note
                )
                stored.updatedAt = row.clientUpdatedAt
                context.insert(stored)
                byID[row.id] = stored
            }
        }
        local = Array(byID.values)
    }

    private func merge(
        _ remote: [CloudBeanRow],
        into local: inout [StoredBean],
        known: Set<UUID>,
        context: ModelContext
    ) {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for row in remote {
            if row.deletedAt != nil {
                if let stored = byID.removeValue(forKey: row.id) {
                    context.delete(stored)
                }
            } else if let stored = byID[row.id] {
                if row.clientUpdatedAt > stored.updatedAt,
                   let profile = row.decodedProfile {
                    stored.update(with: profile)
                    stored.updatedAt = row.clientUpdatedAt
                }
            } else if !known.contains(row.id), let profile = row.decodedProfile {
                let stored = StoredBean(profile: profile)
                stored.updatedAt = row.clientUpdatedAt
                context.insert(stored)
                byID[row.id] = stored
            }
        }
        local = Array(byID.values)
    }

    private func merge(
        _ remote: [CloudRecipeRow],
        into local: inout [StoredRecipe],
        known: Set<UUID>,
        context: ModelContext
    ) {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for row in remote {
            if row.deletedAt != nil {
                if let stored = byID.removeValue(forKey: row.id) {
                    context.delete(stored)
                }
            } else if let stored = byID[row.id] {
                if row.clientUpdatedAt > stored.updatedAt,
                   let recipe = row.decodedRecipe {
                    stored.update(with: recipe)
                    stored.updatedAt = row.clientUpdatedAt
                }
            } else if !known.contains(row.id), let recipe = row.decodedRecipe {
                let stored = StoredRecipe(recipe: recipe)
                stored.updatedAt = row.clientUpdatedAt
                context.insert(stored)
                byID[row.id] = stored
            }
        }
        local = Array(byID.values)
    }

    private func merge(
        _ remote: [CloudBrewRow],
        into local: inout [StoredBrew],
        known: Set<UUID>,
        context: ModelContext
    ) {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for row in remote {
            if row.deletedAt != nil {
                if let stored = byID.removeValue(forKey: row.id) {
                    context.delete(stored)
                }
            } else if let stored = byID[row.id] {
                let localDate = stored.updatedAt ?? stored.completedAt
                if row.clientUpdatedAt > localDate,
                   let entry = row.decodedEntry {
                    stored.update(with: entry)
                    stored.updatedAt = row.clientUpdatedAt
                }
            } else if !known.contains(row.id), let entry = row.decodedEntry {
                let stored = StoredBrew(entry: entry)
                stored.updatedAt = row.clientUpdatedAt
                context.insert(stored)
                byID[row.id] = stored
            }
        }
        local = Array(byID.values)
    }
}

struct CloudSyncSummary {
    let beans: Int
    let recipes: Int
    let brews: Int
    var maintenance: Int = 0
    var total: Int { beans + recipes + brews + maintenance }
}

private struct CloudMaintenanceRow: Codable {
    let userID: UUID
    let id: UUID
    let task: String
    let performedAt: Date
    let note: String?
    let clientUpdatedAt: Date
    let deletedAt: Date?

    init(userID: UUID, stored: StoredMaintenanceEvent) {
        self.userID = userID
        id = stored.id
        task = stored.task
        performedAt = stored.performedAt
        note = stored.note
        clientUpdatedAt = stored.updatedAt
        deletedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id
        case task
        case performedAt = "performed_at"
        case note
        case clientUpdatedAt = "client_updated_at"
        case deletedAt = "deleted_at"
    }
}

private struct CloudProfileRow: Encodable {
    let userID: UUID
    let initialSyncCompletedAt: Date
    let lastClientSyncAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case initialSyncCompletedAt = "initial_sync_completed_at"
        case lastClientSyncAt = "last_client_sync_at"
    }
}

private struct CloudTombstone: Encodable {
    let deletedAt: Date
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

private struct CloudBeanRow: Codable {
    let userID: UUID
    let id: UUID
    let name: String
    let roaster: String
    let remainingWeightGrams: Double
    let archived: Bool
    let payloadJSON: String
    let clientUpdatedAt: Date
    let deletedAt: Date?

    init(userID: UUID, stored: StoredBean) {
        self.userID = userID
        id = stored.id
        name = stored.name
        roaster = stored.roaster
        remainingWeightGrams = stored.remainingWeightGrams
        archived = stored.archived
        payloadJSON = String(decoding: stored.payload, as: UTF8.self)
        clientUpdatedAt = stored.updatedAt
        deletedAt = nil
    }

    var decodedProfile: BeanProfile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BeanProfile.self, from: Data(payloadJSON.utf8))
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id, name, roaster, archived
        case remainingWeightGrams = "remaining_weight_grams"
        case payloadJSON = "payload_json"
        case clientUpdatedAt = "client_updated_at"
        case deletedAt = "deleted_at"
    }
}

private struct CloudRecipeRow: Codable {
    let userID: UUID
    let id: UUID
    let name: String
    let roaster: String
    let origin: String
    let brewStyle: String?
    let generatedByAI: Bool
    let servings: Int?
    let beanID: UUID?
    let payloadJSON: String
    let clientUpdatedAt: Date
    let deletedAt: Date?

    init(userID: UUID, stored: StoredRecipe, validBeanIDs: Set<UUID>) {
        self.userID = userID
        id = stored.id
        name = stored.name
        roaster = stored.roaster
        origin = stored.origin
        brewStyle = stored.brewStyleRaw
        generatedByAI = stored.generatedByAI ?? false
        servings = stored.servings
        beanID = stored.beanID.flatMap { validBeanIDs.contains($0) ? $0 : nil }
        payloadJSON = String(decoding: stored.payload, as: UTF8.self)
        clientUpdatedAt = stored.updatedAt
        deletedAt = nil
    }

    var decodedRecipe: Recipe? {
        try? JSONDecoder().decode(Recipe.self, from: Data(payloadJSON.utf8))
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id, name, roaster, origin, servings
        case brewStyle = "brew_style"
        case generatedByAI = "generated_by_ai"
        case beanID = "bean_id"
        case payloadJSON = "payload_json"
        case clientUpdatedAt = "client_updated_at"
        case deletedAt = "deleted_at"
    }
}

private struct CloudBrewRow: Codable {
    let userID: UUID
    let id: UUID
    let recipeID: UUID?
    let beanID: UUID?
    let recipeName: String
    let beanName: String?
    let completedAt: Date
    let duration: Double
    let rating: Int?
    let brewStyle: String?
    let generatedByAI: Bool
    let wasSimulated: Bool
    let servings: Int?
    let water: Double?
    let coffeeWeight: Double?
    let steps: Int?
    let payloadJSON: String
    let clientUpdatedAt: Date
    let deletedAt: Date?

    init(
        userID: UUID,
        stored: StoredBrew,
        validBeanIDs: Set<UUID>,
        validRecipeIDs: Set<UUID>
    ) {
        self.userID = userID
        id = stored.id
        recipeID = stored.recipeID.flatMap { validRecipeIDs.contains($0) ? $0 : nil }
        beanID = stored.beanID.flatMap { validBeanIDs.contains($0) ? $0 : nil }
        recipeName = stored.recipeName
        beanName = stored.beanName
        completedAt = stored.completedAt
        duration = stored.duration
        rating = stored.rating
        brewStyle = stored.brewStyleRaw
        generatedByAI = stored.generatedByAI ?? false
        wasSimulated = stored.wasSimulated ?? false
        servings = stored.servings
        water = stored.water
        coffeeWeight = stored.coffeeWeight
        steps = stored.steps
        payloadJSON = String(decoding: stored.payload, as: UTF8.self)
        clientUpdatedAt = stored.updatedAt ?? stored.completedAt
        deletedAt = nil
    }

    var decodedEntry: BrewHistoryEntry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BrewHistoryEntry.self, from: Data(payloadJSON.utf8))
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case id, rating, servings
        case recipeID = "recipe_id"
        case beanID = "bean_id"
        case recipeName = "recipe_name"
        case beanName = "bean_name"
        case completedAt = "completed_at"
        case duration = "duration_seconds"
        case brewStyle = "brew_style"
        case generatedByAI = "generated_by_ai"
        case wasSimulated = "was_simulated"
        case water = "water_ml"
        case coffeeWeight = "coffee_weight_grams"
        case steps = "step_count"
        case payloadJSON = "payload_json"
        case clientUpdatedAt = "client_updated_at"
        case deletedAt = "deleted_at"
    }
}

private struct CloudFunctionError: Decodable {
    let error: String
}

enum CloudError: LocalizedError {
    case notSignedIn
    case syncAlreadyRunning
    case invalidResponse
    case function(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to Supabase to sync or use Gemini."
        case .syncAlreadyRunning: "A cloud sync is already running."
        case .invalidResponse: "The cloud service returned an invalid response."
        case let .function(message): message
        }
    }
}
