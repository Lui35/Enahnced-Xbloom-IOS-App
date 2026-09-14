import Foundation
import Observation
import SwiftData
import XBloomCore

/// Shared lifecycle for recipe and bean jobs: account isolation, polling, cancellation
/// and collection after durable, idempotent local storage. Each instance owns one library.
@MainActor
@Observable
final class RecipeGenerationCoordinator {
    enum Library { case recipes, beans }
    struct Pending: Identifiable, Equatable {
        let id: UUID
        let beanID: UUID?
        let beanName: String
        let style: BrewStyle
        let cups: Int
        let startedAt: Date
        var sourceBrewID: UUID? = nil
        var photoCount: Int = 0
        var serverAccepted: Bool = true

        var isEnhancement: Bool { sourceBrewID != nil }
    }

    private static let staleAfter: TimeInterval = 240
    private(set) var pending: [Pending] = []
    private(set) var lastCompleted: Recipe?
    private(set) var lastImported: BeanProfile?
    private(set) var lastError: String?
    private(set) var libraryRequestID: UUID?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let beanGenerator: (any BeanJobGenerating)?
    @ObservationIgnored private let cloud: any RecipeJobStore
    @ObservationIgnored private let gemini: any RecipeJobGenerating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let save: (ModelContext) throws -> Void
    @ObservationIgnored private let automaticallyPoll: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var accountID: UUID?
    private var submitting: Set<UUID> = []
    @ObservationIgnored private var cancellations: Set<UUID> = []
    @ObservationIgnored private var lookupFailed = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshRequested = false

    var isWorking: Bool { !pending.isEmpty }

    init(
        cloud: any RecipeJobStore, gemini: any RecipeJobGenerating,
        defaults: UserDefaults = .standard, automaticallyPoll: Bool = true,
        library: Library = .recipes, beanGenerator: (any BeanJobGenerating)? = nil,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.library = library
        self.beanGenerator = beanGenerator
        self.cloud = cloud
        self.gemini = gemini
        self.defaults = defaults
        self.automaticallyPoll = automaticallyPoll
        self.save = save
    }

    func pending(forBean beanID: UUID?) -> Pending? {
        guard let beanID else { return nil }
        return pending.first { $0.beanID == beanID }
    }

    /// Called on sign-out as well as sign-in, so old-account work cannot leak into the UI.
    func accountChanged() {
        let next = cloud.isAuthenticated ? cloud.userID : nil
        guard next != accountID else { return }
        pollTask?.cancel()
        pollTask = nil
        accountID = next
        pending = []
        submitting = []
        lastCompleted = nil
        lastImported = nil
        libraryRequestID = nil
        lastError = nil
        lookupFailed = false
        cancellations = Set((next.flatMap { defaults.stringArray(forKey: cancellationKey($0)) } ?? [])
            .compactMap(UUID.init(uuidString:)))
    }

    @discardableResult
    func start(
        bean: BeanProfile?, style: BrewStyle, cups: Int, goals: [String], notes: String,
        pours: Int? = nil, beanDescription: String = "", useGrinder: Bool = true,
        context: ModelContext
    ) -> UUID {
        accountChanged()
        let id = UUID()
        guard let userID = accountID else {
            lastError = CloudError.notSignedIn.localizedDescription
            return id
        }
        self.context = context
        let description = beanDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let beanName = bean?.name ?? (description.isEmpty ? "No bean attached" : description)
        pending.append(Pending(id: id, beanID: bean?.id, beanName: beanName,
                               style: style, cups: cups, startedAt: Date()))
        submitting.insert(id)
        libraryRequestID = id
        lastError = nil
        submit(id: id, userID: userID, context: context) { [gemini] in
            try await gemini.startRecipeJob(
                requestID: id, userID: userID,
                context: AIJobRow.Context(beanID: bean?.id, beanName: beanName,
                                          style: style.rawValue, cups: cups, useGrinder: useGrinder),
                for: bean, style: style, cups: cups, goals: goals, notes: notes,
                pours: pours, beanDescription: beanDescription
            )
        }
        return id
    }

    @discardableResult
    func startEnhancement(
        original: Recipe, bean: BeanProfile, brew: BrewHistoryEntry,
        rating: Int, feedbackTags: [String], goals: [String], notes: String,
        context: ModelContext
    ) -> UUID? {
        accountChanged()
        guard let userID = accountID else {
            lastError = CloudError.notSignedIn.localizedDescription
            return nil
        }
        if let existing = pending.first(where: { $0.sourceBrewID == brew.id }) { return existing.id }
        let id = UUID()
        let style: BrewStyle = original.brewStyle == .iced ? .iced : .hot
        let cups = original.servings ?? 1
        self.context = context
        pending.append(Pending(id: id, beanID: bean.id, beanName: bean.name,
                               style: style, cups: cups, startedAt: Date(), sourceBrewID: brew.id))
        submitting.insert(id)
        libraryRequestID = id
        lastError = nil
        let job = AIJobRow.Context(
            beanID: bean.id, beanName: bean.name, style: style.rawValue, cups: cups,
            useGrinder: original.useGrinder, parentRecipeID: original.id,
            sourceBrewID: brew.id, beanSnapshot: bean
        )
        submit(id: id, userID: userID, context: context) { [gemini] in
            try await gemini.startEnhancementJob(
                requestID: id, userID: userID, context: job, original: original,
                bean: bean, brew: brew, rating: rating, feedbackTags: feedbackTags,
                goals: goals, notes: notes
            )
        }
        return id
    }

    func isSubmitting(_ id: UUID) -> Bool { submitting.contains(id) }

    @discardableResult
    func startBeanImport(images: [(data: Data, mimeType: String)], context: ModelContext) -> UUID? {
        accountChanged()
        guard let userID = accountID else {
            lastError = CloudError.notSignedIn.localizedDescription
            return nil
        }
        guard library == .beans, let beanGenerator, !images.isEmpty else {
            lastError = GeminiError.missingImages.localizedDescription
            return nil
        }
        guard images.reduce(0, { $0 + $1.data.count }) <= 14_000_000 else {
            lastError = GeminiError.imagesTooLarge.localizedDescription
            return nil
        }
        let id = UUID()
        self.context = context
        pending.append(Pending(id: id, beanID: nil, beanName: "Bag photos", style: .hot,
                               cups: 1, startedAt: Date(), photoCount: images.count, serverAccepted: false))
        submitting.insert(id)
        libraryRequestID = id
        lastError = nil
        submit(id: id, userID: userID, context: context) {
            try await beanGenerator.startBeanJob(
                requestID: id, userID: userID,
                context: .init(beanID: nil, beanName: "Bag photos", style: "hot", cups: 1,
                               useGrinder: false, photoCount: images.count), images: images
            )
        }
        return id
    }

    private func submit(
        id: UUID, userID: UUID, context: ModelContext,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                guard isCurrent(userID) else { return }
                if let index = pending.firstIndex(where: { $0.id == id }) {
                    pending[index].serverAccepted = true
                }
            } catch {
                guard isCurrent(userID) else { return }
                if !cancellations.contains(id) { lastError = error.localizedDescription }
                // A lost acknowledgement may still have created a job. Reconcile with the server.
            }
            guard isCurrent(userID) else { return }
            submitting.remove(id)
            await refresh(context: context)
        }
    }

    /// Serialize collection across poll, startup and foreground events, including their awaits.
    func refresh(context: ModelContext) async {
        self.context = context
        accountChanged()
        guard accountID != nil else { return }
        if isRefreshing {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            if let userID = accountID { await refreshOnce(userID: userID, context: context) }
            accountChanged()
        } while refreshRequested && accountID != nil
        startPolling()
    }

    private func refreshOnce(userID: UUID, context: ModelContext) async {
        await flushCancellations(userID: userID)
        guard isCurrent(userID) else { return }
        let rows: [AIJobRow]
        do {
            rows = try await cloud.openAIJobs(for: userID).filter {
                library == .beans ? $0.action == "importBean"
                    : ["generateRecipe", "enhanceRecipe"].contains($0.action)
            }
        } catch {
            guard isCurrent(userID) else { return }
            lookupFailed = true
            lastError = "Could not check AI results. Your result may already be ready; it will be checked again when the connection recovers."
            return // Keep known work until connectivity returns; do not imply AI is still running.
        }
        guard isCurrent(userID) else { return }
        if lookupFailed {
            lastError = nil
            lookupFailed = false
        }
        var running: [Pending] = []
        for row in rows where !cancellations.contains(row.id) {
            guard isCurrent(userID) else { return }
            switch row.status {
            case "started":
                if Date().timeIntervalSince(row.createdAt) > Self.staleAfter {
                    // Never consume an unfinished result: a late result must remain recoverable.
                    lastError = "This \(library == .beans ? "import" : "recipe") is taking longer than expected. Reopen the app to check again. A result saved later will still be recovered."
                } else {
                    running.append(card(row))
                }
            case "succeeded":
                if !(await collect(row, userID: userID, context: context)) {
                    running.append(card(row)) // Failed saves/acknowledgements must continue polling.
                }
            case "failed":
                lastError = library == .beans
                    ? "The bag could not be imported. Please try the photos again. (\(row.errorCode ?? "unknown error"))"
                    : Self.message(forErrorCode: row.errorCode)
                do { try await cloud.finishAIJob(row.id, for: userID) }
                catch { running.append(card(row)) }
            default: break
            }
        }
        guard isCurrent(userID) else { return }
        let known = Set(rows.map(\.id))
        pending = running + pending.filter {
            submitting.contains($0.id) && !known.contains($0.id) && !cancellations.contains($0.id)
        }
    }

    func cancel(_ id: UUID) {
        accountChanged()
        guard let userID = accountID else { return }
        cancellations.insert(id)
        persistCancellations(userID)
        pending.removeAll { $0.id == id }
        Task { [weak self] in
            guard let self, let context = self.context else { return }
            await self.refresh(context: context)
        }
    }

    private func flushCancellations(userID: UUID) async {
        for id in cancellations where !submitting.contains(id) {
            guard isCurrent(userID) else { return }
            do {
                let acknowledged = try await cloud.cancelAIJob(id, for: userID)
                guard isCurrent(userID) else { return }
                if acknowledged {
                    cancellations.remove(id)
                    persistCancellations(userID)
                }
            } catch {
                // Intent survives relaunch and is retried on the next poll/foreground event.
            }
        }
    }

    private func collect(_ row: AIJobRow, userID: UUID, context: ModelContext) async -> Bool {
        do {
            if library == .beans {
                guard let beanGenerator else { throw GeminiError.invalidResponse }
                let result = try RecipeJobPersistence.collectBean(row, userID: userID, in: context, save: save) {
                    guard let response = row.response else { throw GeminiError.invalidResponse }
                    return try beanGenerator.beanResult(from: response)
                }
                if let bean = result.bean {
                    lastImported = bean
                    MachineFeedback.acknowledged()
                }
                if let rejection = result.rejection { lastError = rejection }
                try await cloud.finishAIJob(row.id, for: userID)
                return true
            }
            let result = try RecipeJobPersistence.collect(
                row, userID: userID, in: context, save: save
            ) { bean in
                guard let response = row.response else { throw GeminiError.invalidResponse }
                let result = try gemini.recipeResult(from: response)
                var recipe = try result.recipe(
                    bean: bean, cups: row.context?.cups,
                    requestedStyle: row.context.flatMap { BrewStyle(rawValue: $0.style) }
                )
                recipe.useGrinder = row.context?.useGrinder ?? true
                recipe.parentRecipeID = row.context?.parentRecipeID
                recipe.sourceBrewID = row.context?.sourceBrewID
                if row.action == "enhanceRecipe" {
                    recipe.aiDescription = "Enhanced from your feedback\n\nWhat changed and why\n" + (recipe.aiDescription ?? "")
                }
                return recipe
            }
            if let recipe = result.recipe {
                lastCompleted = recipe
                MachineFeedback.acknowledged()
            }
            if let rejection = result.rejection { lastError = rejection }
            try await cloud.finishAIJob(row.id, for: userID)
            return true
        } catch {
            guard isCurrent(userID) else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    private func isCurrent(_ userID: UUID) -> Bool {
        cloud.isAuthenticated && cloud.userID == userID && accountID == userID
    }

    private func card(_ row: AIJobRow) -> Pending {
        Pending(id: row.id, beanID: row.context?.beanID,
                beanName: row.context?.beanName ?? "No bean attached",
                style: row.context.flatMap { BrewStyle(rawValue: $0.style) } ?? .hot,
                cups: row.context?.cups ?? 1, startedAt: row.createdAt,
                sourceBrewID: row.context?.sourceBrewID, photoCount: row.context?.photoCount ?? 1)
    }

    private func cancellationKey(_ userID: UUID) -> String { "\(library == .beans ? "beanJobs" : "recipeJobs").cancelled.\(userID)" }
    private func persistCancellations(_ userID: UUID) {
        defaults.set(cancellations.map(\.uuidString), forKey: cancellationKey(userID))
    }

    private func startPolling() {
        guard automaticallyPoll, pollTask == nil, (!pending.isEmpty || lookupFailed), let userID = accountID else { return }
        pollTask = Task { [weak self] in
            while let self, (!self.pending.isEmpty || self.lookupFailed), self.isCurrent(userID), !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                guard !Task.isCancelled, let context = self.context else { break }
                await self.refresh(context: context)
            }
            if !Task.isCancelled { self?.pollTask = nil }
        }
    }

    func clearLastImported() { lastImported = nil }
    func clearLastCompleted() { lastCompleted = nil }
    func clearError() { lastError = nil }

    private static func message(forErrorCode code: String?) -> String {
        switch code {
        case "timeout": "Gemini took too long to answer. Try designing the recipe again."
        case "upstream_error": "Gemini could not be reached. Try designing the recipe again."
        case let code?: "The recipe could not be designed (\(code))."
        case nil: "The recipe could not be designed. Try again."
        }
    }

    #if DEBUG
    func seedPreviewPendingIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-seedPendingRecipe"), pending.isEmpty else { return }
        pending.append(Pending(id: UUID(), beanID: nil, beanName: "Relationship Preview Bean",
                               style: .hot, cups: 1, startedAt: Date(), photoCount: library == .beans ? 2 : 0))
    }
    #endif
}
