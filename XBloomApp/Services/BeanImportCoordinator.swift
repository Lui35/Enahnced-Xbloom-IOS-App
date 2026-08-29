import Foundation
import Observation
import SwiftData
import XBloomCore

/// Owns bean-label imports so they outlive the screen that started them.
///
/// The same problem the recipe designer had: the request was owned by a sheet
/// and cancelled when it closed, so photographing a bag meant standing on that
/// screen until the model answered. Reading a label takes as long as it takes.
@MainActor
@Observable
final class BeanImportCoordinator {
    struct Pending: Identifiable, Equatable {
        let id: UUID
        /// The number of photos being read, which is all there is to say about
        /// a bag whose name is exactly what the request is trying to find out.
        let photoCount: Int
        let startedAt: Date
    }

    private(set) var pending: [Pending] = []
    /// The bean that just landed, for a screen that wants to point at it.
    private(set) var lastImported: BeanProfile?
    private(set) var lastError: String?

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    var isWorking: Bool { !pending.isEmpty }

    /// Starts an import and returns its id. The caller is free to disappear.
    ///
    /// The bean is saved as soon as it arrives, flagged as unverified: a bag
    /// read off a photo is a draft, and the library is a better place to keep
    /// a draft than a sheet nobody is looking at.
    @discardableResult
    func start(
        images: [(data: Data, mimeType: String)],
        gemini: GeminiService,
        context: ModelContext
    ) -> UUID {
        let id = UUID()
        pending.append(Pending(id: id, photoCount: images.count, startedAt: Date()))
        lastError = nil

        tasks[id] = Task { @MainActor [weak self] in
            defer {
                self?.pending.removeAll { $0.id == id }
                self?.tasks[id] = nil
            }
            do {
                let result = try await gemini.importBean(images: images)
                try Task.checkCancellation()
                let profile = BeanProfile(
                    name: result.name,
                    roaster: result.roaster ?? "",
                    country: result.country ?? "",
                    region: result.region ?? "",
                    producer: result.producer ?? "",
                    species: result.species ?? "Arabica",
                    variety: result.variety ?? "",
                    process: result.process ?? "Washed",
                    processDetail: result.processDetail ?? "",
                    altitudeMASL: result.altitudeMASL,
                    roastLevel: result.roastLevel ?? "Medium-light",
                    acidityLevel: result.acidityLevel,
                    tastingNotes: result.tastingNotes ?? ""
                )
                context.insert(StoredBean(profile: profile, needsVerification: true))
                try context.save()
                self?.lastImported = profile
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

    func clearLastImported() { lastImported = nil }
    func clearError() { lastError = nil }

    #if DEBUG
    /// Shows the shelf's in-progress card without a network round trip.
    /// Launch with `-seedPendingRecipe`.
    func seedPreviewPendingIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-seedPendingRecipe"),
              pending.isEmpty else { return }
        pending.append(Pending(id: UUID(), photoCount: 2, startedAt: Date()))
    }
    #endif
}
