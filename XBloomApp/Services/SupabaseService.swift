import Foundation
import Observation
import Supabase
import SwiftData
import XBloomCore

@MainActor
@Observable
final class SupabaseService {
    /// Where this build's backend lives, read from `Secrets.xcconfig` at build
    /// time rather than written here.
    ///
    /// A public repository that carries a working project URL and key hands
    /// every reader an account in somebody else's database — and, through the
    /// AI function, somebody else's model quota. Row Level Security keeps rows
    /// private either way, but quota is not a row.
    ///
    /// Both are empty in a clean checkout, and that is a supported state: the
    /// library, the recipe editor, and every Bluetooth feature are local.
    static let projectURL: URL? = {
        let host = configuration("SupabaseHost")
        guard !host.isEmpty else { return nil }
        return URL(string: "https://\(host)")
    }()

    static let publishableKey = configuration("SupabasePublishableKey")

    /// Whether this build has a backend at all.
    static var isConfigured: Bool { projectURL != nil && !publishableKey.isEmpty }

    private static func configuration(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

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
        // An unconfigured build still needs a client to exist; every call
        // through it fails, and `isConfigured` is what the UI asks first so
        // nothing tries.
        client = SupabaseClient(
            supabaseURL: Self.projectURL ?? URL(string: "https://unconfigured.invalid")!,
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

    /// Calls the AI function and waits for Gemini to answer.
    ///
    /// - Parameters:
    ///   - requestID: Supplying one asks the function to answer immediately and
    ///     finish in the background, leaving the result on the row. The same id
    ///     resent is a duplicate the function refuses to bill twice, so a retry
    ///     is safe. Without one the call blocks for the whole Gemini round trip,
    ///     which is still what the short actions want.
    ///   - context: Handed back untouched on the row, for a result collected by
    ///     a launch that no longer remembers what it asked for.
    @discardableResult
    func invokeAI(
        action: String,
        model: String,
        body: [String: Any],
        requestID: UUID? = nil,
        context: [String: Any]? = nil
    ) async throws -> Data {
        guard let projectURL = Self.projectURL else { throw CloudError.notConfigured }
        let session = try await requireSession()
        var request = URLRequest(url: projectURL.appending(path: "functions/v1/coffee-ai"))
        request.httpMethod = "POST"
        request.timeoutInterval = 85
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        var payload: [String: Any] = [
            "action": action,
            "model": model,
            "body": body,
        ]
        if let requestID { payload["requestID"] = requestID.uuidString.lowercased() }
        if let context { payload["context"] = context }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(CloudFunctionError.self, from: data).error)
            throw CloudError.function(message ?? "Cloud AI returned HTTP \(http.statusCode).")
        }
        return data
    }

    /// Every AI request this account has not accounted for yet: still running,
    /// or finished and waiting to be turned into a recipe.
    func openAIJobs() async throws -> [AIJobRow] {
        guard Self.isConfigured else { return [] }
        let session = try await requireSession()
        return try await client.schema("public").setAuth(session.accessToken)
            .from("ai_request_usage")
            .select("request_id,action,status,error_code,context,response,created_at")
            .eq("user_id", value: session.user.id)
            .is("consumed_at", value: nil)
            .in("status", values: ["started", "succeeded", "failed"])
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Marks a result as landed, so the next launch does not save it twice.
    func finishAIJob(_ requestID: UUID) async throws {
        try await updateAIJob(requestID, values: ["consumed_at": Self.timestamp()])
    }

    /// Gives up on a request. The row stays: Gemini has usually already been
    /// called, and it still counts against the rate limit.
    func cancelAIJob(_ requestID: UUID) async throws {
        try await updateAIJob(
            requestID,
            values: ["status": "cancelled", "consumed_at": Self.timestamp()]
        )
    }

    private func updateAIJob(_ requestID: UUID, values: [String: String]) async throws {
        let session = try await requireSession()
        try await client.schema("public").setAuth(session.accessToken)
            .from("ai_request_usage")
            .update(values)
            .eq("user_id", value: session.user.id)
            .eq("request_id", value: requestID)
            .execute()
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
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
        // A sync can pull another device's brews down and push this one past
        // the limit, so the trim runs here as well as after a brew.
        try? LocalLibrary.pruneHistory(in: context)
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

    /// Marks rows deleted in the cloud and throws away what made them big.
    ///
    /// The marker itself has to stay: it is how another device learns the
    /// record is gone, and a row removed outright is simply re-uploaded by the
    /// next device that still has it. What does not have to stay is the
    /// payload — the recipe program, the bean profile, every telemetry sample
    /// of a brew — which is all of the size. A tombstone keeps an id and a
    /// date; the rest is emptied.
    private func pushDeletions(
        table: String,
        userID: UUID,
        deletedIDs: Set<UUID>,
        database: PostgrestClient
    ) async throws {
        guard !deletedIDs.isEmpty else { return }
        let now = Date()
        let tombstone = CloudTombstone(deletedAt: now, clientUpdatedAt: now)
        let emptied = CloudEmptiedTombstone(deletedAt: now, clientUpdatedAt: now, payloadJSON: "{}")
        for id in deletedIDs {
            let query = database.from(table)
            // maintenance_events carry no payload column to empty.
            let update = table == "maintenance_events"
                ? try query.update(tombstone)
                : try query.update(emptied)
            try await update
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

/// A tombstone that also drops the payload, which is everything that made the
/// row worth storing while it existed.
private struct CloudEmptiedTombstone: Encodable {
    let deletedAt: Date
    let clientUpdatedAt: Date
    let payloadJSON: String

    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case payloadJSON = "payload_json"
    }
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

enum CloudError: LocalizedError {
    case notSignedIn
    case notConfigured
    case syncAlreadyRunning
    case invalidResponse
    case function(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to Supabase to sync or use Gemini."
        case .notConfigured:
            "This build has no Supabase project. Add one in Secrets.xcconfig and rebuild — "
                + "see INSTALLATION.md. Brewing and your library work without it."
        case .syncAlreadyRunning: "A cloud sync is already running."
        case .invalidResponse: "The cloud service returned an invalid response."
        case let .function(message): message
        }
    }
}
