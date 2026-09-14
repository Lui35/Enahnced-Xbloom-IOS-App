import Foundation
import Observation
import SwiftData
import XBloomCore

/// Bean-library presentation over the same recoverable job lifecycle as recipes.
@MainActor
@Observable
final class BeanImportCoordinator {
    private let jobs: RecipeGenerationCoordinator

    init(cloud: any RecipeJobStore, gemini: any RecipeJobGenerating & BeanJobGenerating,
         defaults: UserDefaults = .standard, automaticallyPoll: Bool = true,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        jobs = RecipeGenerationCoordinator(cloud: cloud, gemini: gemini,
            defaults: defaults, automaticallyPoll: automaticallyPoll,
            library: .beans, beanGenerator: gemini, save: save)
    }

    var pending: [RecipeGenerationCoordinator.Pending] { jobs.pending }
    var lastImported: BeanProfile? { jobs.lastImported }
    var lastError: String? { jobs.lastError }
    var isWorking: Bool { jobs.isWorking }
    func isUploading(_ id: UUID) -> Bool { jobs.isSubmitting(id) }

    @discardableResult
    func start(images: [(data: Data, mimeType: String)], context: ModelContext) -> UUID? {
        jobs.startBeanImport(images: images, context: context)
    }

    func accountChanged() { jobs.accountChanged() }
    func refresh(context: ModelContext) async { await jobs.refresh(context: context) }
    func cancel(_ id: UUID) { jobs.cancel(id) }
    func clearLastImported() { jobs.clearLastImported() }
    func clearError() { jobs.clearError() }

    #if DEBUG
    func seedPreviewPendingIfRequested() { jobs.seedPreviewPendingIfRequested() }
    #endif
}
