import Foundation
import Observation
import SwiftData
import XBloomCore

/// Owns AI recipe generations so they outlive the screen — and now the process
/// — that started them.
///
/// The designer used to own its own task and cancel it in `onDisappear`, which
/// meant leaving the sheet silently threw away work that had already been paid
/// for. Moving the request here fixed that, but only until the app itself went
/// away: the phone still held the HTTP connection open for the whole Gemini
/// call, so a locked screen or a tunnel lost a recipe the backend had already
/// finished writing.
///
/// So the phone no longer waits. `coffee-ai` answers immediately, finishes in
/// the background, and leaves the result on the request row; this polls for it
/// while something is in flight and collects it whenever the app is next
/// running. The card on the library screen is a view of those rows rather than
/// of an in-memory task, which is why it survives a relaunch.
@MainActor
@Observable
final class RecipeGenerationCoordinator {
    struct Pending: Identifiable, Equatable {
        let id: UUID
        let beanID: UUID?
        /// What the card calls it: the bean's name, the user's own description
        /// of what is in the hopper, or nothing at all.
        let beanName: String
        let style: BrewStyle
        let cups: Int
        let startedAt: Date
    }

    /// How often to ask about a request already in flight. There is no realtime
    /// subscription in this app, and a generation runs tens of seconds, so this
    /// only runs while a card is on screen waiting for it.
    private static let pollInterval = Duration.seconds(3)

    /// How long a request may sit unfinished before the app stops believing in
    /// it. Without this, a background task that died without patching its row
    /// would leave the card spinning forever, on every launch, with cancelling
    /// by hand as the only way out.
    ///
    /// Giving up too early is the more expensive mistake: it consumes the row,
    /// so a result that lands afterwards is never collected and the recipe is
    /// lost. So this stays comfortably clear of `coffee-ai`'s own worst case —
    /// a 75s attempt, a 12s wait, then a 45s retry, near enough two minutes.
    /// Raise it if that budget ever grows.
    private static let staleAfter: TimeInterval = 240

    /// Generations still in flight, oldest first.
    private(set) var pending: [Pending] = []
    /// The most recent recipe to land, for a screen that wants to point at it.
    private(set) var lastCompleted: Recipe?
    private(set) var lastError: String?

    @ObservationIgnored private let cloud: SupabaseService
    @ObservationIgnored private let gemini: GeminiService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Held so a result can be saved by the poll, which has no view to hand it
    /// one.
    @ObservationIgnored private var context: ModelContext?

    var isWorking: Bool { !pending.isEmpty }

    init(cloud: SupabaseService, gemini: GeminiService) {
        self.cloud = cloud
        self.gemini = gemini
    }

    func pending(forBean beanID: UUID?) -> Pending? {
        guard let beanID else { return nil }
        return pending.first { $0.beanID == beanID }
    }

    /// Starts a generation and returns its id. The caller is free to disappear,
    /// and so is the app.
    @discardableResult
    func start(
        bean: BeanProfile?,
        style: BrewStyle,
        cups: Int,
        goals: [String],
        notes: String,
        pours: Int? = nil,
        beanDescription: String = "",
        useGrinder: Bool = true,
        context: ModelContext
    ) -> UUID {
        let id = UUID()
        self.context = context
        let describedBean = beanDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let beanName = bean?.name
            ?? (describedBean.isEmpty ? "No bean attached" : describedBean)
        // Shown before the backend has confirmed anything, so the library has a
        // card the moment the designer closes. The next poll replaces it with
        // the row's own version, or removes it if the request never landed.
        pending.append(
            Pending(
                id: id,
                beanID: bean?.id,
                beanName: beanName,
                style: style,
                cups: cups,
                startedAt: Date()
            )
        )
        lastError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await gemini.startRecipeJob(
                    requestID: id,
                    context: AIJobRow.Context(
                        beanID: bean?.id,
                        beanName: beanName,
                        style: style.rawValue,
                        cups: cups,
                        useGrinder: useGrinder
                    ),
                    for: bean,
                    style: style,
                    cups: cups,
                    goals: goals,
                    notes: notes,
                    pours: pours,
                    beanDescription: beanDescription
                )
                startPolling()
            } catch {
                pending.removeAll { $0.id == id }
                lastError = error.localizedDescription
            }
        }
        return id
    }

    /// Collects anything the backend has finished, and rebuilds the in-flight
    /// list from the rows. Safe to call on every launch.
    func refresh(context: ModelContext) async {
        self.context = context
        guard cloud.isAuthenticated else { return }
        let rows: [AIJobRow]
        do {
            // A row with no context predates this change: the client that made
            // it waited for its answer inline and already has it. Collecting
            // those would replay a backlog of long-dead failures as fresh
            // banners on the first launch after upgrading.
            rows = try await cloud.openAIJobs().filter {
                $0.action == "generateRecipe" && $0.context != nil
            }
        } catch {
            // An unreachable backend is not worth a banner: the cards stay, and
            // the next poll or launch asks again.
            return
        }

        var running: [Pending] = []
        for row in rows {
            switch row.status {
            case "started" where Date().timeIntervalSince(row.createdAt) > Self.staleAfter:
                lastError = "The recipe was never finished. Try designing it again."
                try? await cloud.abandonAIJob(row.requestID)
            case "started":
                running.append(
                    Pending(
                        id: row.requestID,
                        beanID: row.context?.beanID,
                        beanName: row.context?.beanName ?? "No bean attached",
                        style: row.context.flatMap { BrewStyle(rawValue: $0.style) } ?? .hot,
                        cups: row.context?.cups ?? 1,
                        startedAt: row.createdAt
                    )
                )
            case "succeeded":
                await collect(row, context: context)
            case "failed":
                lastError = Self.message(forErrorCode: row.errorCode)
                try? await cloud.finishAIJob(row.requestID)
            default:
                break
            }
        }

        // A request whose POST is still in flight has no row yet, so its
        // optimistic card is kept rather than flickering out and back.
        let known = Set(rows.map(\.requestID))
        pending = running + pending.filter { !known.contains($0.id) }
        if !pending.isEmpty { startPolling() }
    }

    func cancel(_ id: UUID) {
        pending.removeAll { $0.id == id }
        Task { [cloud] in try? await cloud.cancelAIJob(id) }
    }

    /// Clears the "just landed" pointer once a screen has reacted to it.
    func clearLastCompleted() {
        lastCompleted = nil
    }

    func clearError() {
        lastError = nil
    }

    /// Turns a finished row into a saved recipe.
    ///
    /// The row is marked consumed *before* the recipe is written, so a failure
    /// between the two loses one recipe rather than saving it again on every
    /// launch that follows.
    // ponytail: no transaction across two systems; if this ever needs to be
    // exactly-once, put the request id on StoredRecipe and dedupe on it.
    private func collect(_ row: AIJobRow, context: ModelContext) async {
        guard let response = row.response else {
            try? await cloud.finishAIJob(row.requestID)
            return
        }
        do {
            try await cloud.finishAIJob(row.requestID)
        } catch {
            return
        }
        do {
            let result = try gemini.recipeResult(from: response)
            let job = row.context
            var recipe = try result.recipe(
                bean: job?.beanID.flatMap { bean($0, in: context) },
                cups: job?.cups,
                requestedStyle: job.flatMap { BrewStyle(rawValue: $0.style) }
            )
            // Pre-ground coffee changes nothing about the pours and everything
            // about the program the machine runs.
            recipe.useGrinder = job?.useGrinder ?? true
            context.insert(StoredRecipe(recipe: recipe))
            try context.save()
            lastCompleted = recipe
            MachineFeedback.acknowledged()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func bean(_ id: UUID, in context: ModelContext) -> BeanProfile? {
        var descriptor = FetchDescriptor<StoredBean>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.profile
    }

    private func startPolling() {
        guard pollTask == nil, !pending.isEmpty else { return }
        pollTask = Task { @MainActor [weak self] in
            while let self, !self.pending.isEmpty {
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    break
                }
                guard let context = self.context else { break }
                await self.refresh(context: context)
            }
            self?.pollTask = nil
        }
    }

    private static func message(forErrorCode code: String?) -> String {
        switch code {
        case "timeout": "Gemini took too long to answer. Try designing the recipe again."
        case "upstream_error": "Gemini could not be reached. Try designing the recipe again."
        case let code?: "The recipe could not be designed (\(code))."
        case nil: "The recipe could not be designed. Try again."
        }
    }

    #if DEBUG
    /// Shows the library's in-progress card without a network round trip.
    /// Launch with `-seedPendingRecipe`.
    func seedPreviewPendingIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-seedPendingRecipe"),
              pending.isEmpty else { return }
        pending.append(
            Pending(
                id: UUID(),
                beanID: nil,
                beanName: "Relationship Preview Bean",
                style: .hot,
                cups: 1,
                startedAt: Date()
            )
        )
    }
    #endif
}
