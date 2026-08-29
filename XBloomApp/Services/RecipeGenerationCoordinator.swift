import Foundation
import Observation
import SwiftData
import XBloomCore

/// Owns AI recipe generations so they outlive the screen that started them.
///
/// The designer used to own its own task and cancel it in `onDisappear`, which
/// meant leaving the sheet — or switching tabs while it worked — silently threw
/// the request away after it had already been paid for. The work belongs to the
/// app, not to a view: this holds it, writes the recipe when it lands, and
/// gives the library something to show in the meantime.
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

    /// Generations still in flight, oldest first.
    private(set) var pending: [Pending] = []
    /// The most recent recipe to land, for a screen that wants to point at it.
    private(set) var lastCompleted: Recipe?
    private(set) var lastError: String?

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    var isWorking: Bool { !pending.isEmpty }

    func pending(forBean beanID: UUID?) -> Pending? {
        guard let beanID else { return nil }
        return pending.first { $0.beanID == beanID }
    }

    /// Starts a generation and returns its id. The caller is free to disappear.
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
        gemini: GeminiService,
        context: ModelContext
    ) -> UUID {
        let id = UUID()
        let describedBean = beanDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        pending.append(
            Pending(
                id: id,
                beanID: bean?.id,
                beanName: bean?.name
                    ?? (describedBean.isEmpty ? "No bean attached" : describedBean),
                style: style,
                cups: cups,
                startedAt: Date()
            )
        )
        lastError = nil

        tasks[id] = Task { @MainActor [weak self] in
            defer {
                self?.pending.removeAll { $0.id == id }
                self?.tasks[id] = nil
            }
            do {
                let result = try await gemini.generateRecipe(
                    for: bean,
                    style: style,
                    cups: cups,
                    goals: goals,
                    notes: notes,
                    pours: pours,
                    beanDescription: beanDescription
                )
                try Task.checkCancellation()
                var recipe = try result.recipe(bean: bean, cups: cups, requestedStyle: style)
                // Pre-ground coffee changes nothing about the pours and
                // everything about the program the machine runs.
                recipe.useGrinder = useGrinder
                context.insert(StoredRecipe(recipe: recipe))
                try context.save()
                self?.lastCompleted = recipe
                MachineFeedback.acknowledged()
            } catch is CancellationError {
                return
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
        return id
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        pending.removeAll { $0.id == id }
    }

    /// Clears the "just landed" pointer once a screen has reacted to it.
    func clearLastCompleted() {
        lastCompleted = nil
    }

    func clearError() {
        lastError = nil
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
