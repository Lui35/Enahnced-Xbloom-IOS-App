import Foundation
import SwiftData
import Supabase
import Testing
import XBloomCore
@testable import xBloom

private enum TestFailure: Error { case unavailable }

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class JobStore: RecipeJobStore {
    var userID: UUID? = UUID()
    var isAuthenticated: Bool { userID != nil }
    var rows: [AIJobRow] = []
    var fetches = 0
    var acknowledgements = 0
    var cancelFails = false
    var acknowledgeFails = false
    var fetchGate: Gate?
    var beforeAcknowledge: (() throws -> Void)?
    func openAIJobs(for userID: UUID) async throws -> [AIJobRow] {
        fetches += 1
        let snapshot = rows
        if let gate = fetchGate { fetchGate = nil; await gate.wait() }
        return snapshot
    }
    func finishAIJob(_ id: UUID, for userID: UUID) async throws {
        try beforeAcknowledge?()
        if acknowledgeFails { throw TestFailure.unavailable }
        acknowledgements += 1
        rows.removeAll { $0.id == id }
    }
    func cancelAIJob(_ id: UUID, for userID: UUID) async throws -> Bool {
        if cancelFails { throw TestFailure.unavailable }
        guard rows.contains(where: { $0.id == id }) else { return false }
        rows.removeAll { $0.id == id }
        return true
    }
}

@MainActor
private final class Generator: RecipeJobGenerating, BeanJobGenerating {
    var gate: Gate?
    var startedID: UUID?
    var onSubmitted: ((UUID) -> Void)?
    var enhancementContext: AIJobRow.Context?
    func startRecipeJob(requestID: UUID, userID: UUID, context: AIJobRow.Context, for bean: BeanProfile?,
                        style: BrewStyle?, cups: Int?, goals: [String], notes: String,
                        pours: Int?, beanDescription: String) async throws {
        startedID = requestID
        if let gate { await gate.wait() }
        onSubmitted?(requestID)
    }
    func startEnhancementJob(requestID: UUID, userID: UUID, context: AIJobRow.Context,
                             original: Recipe, bean: BeanProfile, brew: BrewHistoryEntry,
                             rating: Int, feedbackTags: [String], goals: [String], notes: String) async throws {
        startedID = requestID
        enhancementContext = context
        if let gate { await gate.wait() }
        onSubmitted?(requestID)
    }
    func startBeanJob(requestID: UUID, userID: UUID, context: AIJobRow.Context,
                      images: [(data: Data, mimeType: String)]) async throws {
        startedID = requestID
        enhancementContext = context
        if let gate { await gate.wait() }
        onSubmitted?(requestID)
    }
    func beanResult(from response: String) throws -> BeanPhotoResult {
        if response == "invalid" { throw TestFailure.unavailable }
        return BeanPhotoResult(name: "Recovered coffee", roaster: "Test roaster",
                               roastDate: "2026-09-01", confidence: [:])
    }
    func recipeResult(from response: String) throws -> AIRecipeResult {
        if response == "invalid" { throw TestFailure.unavailable }
        return AIRecipeResult(name: "Test recipe", methodName: "Test", rationale: "Test",
            brewStyle: "hot", servings: 1, iceGrams: 0, grind: 50, rpm: 80, dose: 15,
            pours: [.init(volume: 225, temp: 90, flow: 3, pauseAfter: 0, pattern: "center",
                          agitationBefore: false, agitationAfter: false)])
    }
}

private func job(_ id: UUID = UUID(), status: String = "succeeded") -> AIJobRow {
    AIJobRow(requestID: id, action: "generateRecipe", status: status, errorCode: nil,
             context: .init(beanID: nil, beanName: "Test", style: "hot", cups: 1, useGrinder: false),
             response: "valid", createdAt: Date())
}

@Suite(.serialized)
@MainActor
struct RecipeGenerationTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "jobs-test-\(UUID())")! }

    @Test func enhancementSubmissionUsesTheSharedPendingJobFlow() async throws {
        let container = try testContainer()
        let store = JobStore()
        let generator = Generator()
        let gate = Gate()
        generator.gate = gate
        var original = RecipeLibrary.defaults[0]
        original.useGrinder = false
        let bean = BeanProfile(name: "Snapshot coffee")
        let brew = BrewHistoryEntry(recipeID: original.id, recipeName: original.name,
            beanID: bean.id, beanName: bean.name, duration: 120, water: 225,
            coffeeWeight: 190, steps: 1, rating: 3)
        let coordinator = RecipeGenerationCoordinator(cloud: store, gemini: generator,
            defaults: defaults(), automaticallyPoll: false)
        let id = try #require(coordinator.startEnhancement(original: original, bean: bean, brew: brew,
            rating: 3, feedbackTags: ["Too sour"], goals: [], notes: "More sweetness",
            context: container.mainContext))
        #expect(coordinator.pending.first?.isEnhancement == true)
        #expect(coordinator.pending.first?.sourceBrewID == brew.id)
        #expect(coordinator.libraryRequestID == id)
        while generator.startedID == nil { await Task.yield() }
        #expect(generator.enhancementContext?.parentRecipeID == original.id)
        #expect(generator.enhancementContext?.beanSnapshot == bean)
        #expect(generator.enhancementContext?.useGrinder == false)
        // Submission outlives the initiating screen and uses the same cancellation path.
        coordinator.cancel(id)
        generator.onSubmitted = { store.rows = [job($0)] }
        gate.release()
        for _ in 0..<100 { await Task.yield() }
        await coordinator.refresh(context: container.mainContext)
        #expect(store.rows.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRecipe>()) == 0)
    }

    @Test func enhancementRecoversLineageDescriptionAndBrewLinkAfterRelaunch() async throws {
        let container = try testContainer()
        let context = container.mainContext
        let bean = BeanProfile(name: "Snapshot coffee", roaster: "Snapshot roaster")
        let original = RecipeLibrary.defaults[0]
        let entry = BrewHistoryEntry(recipeID: original.id, recipeName: original.name,
            beanID: bean.id, beanName: bean.name, duration: 120, water: 225,
            coffeeWeight: 190, steps: 1, rating: 3, notes: "Too sour")
        let storedBrew = StoredBrew(entry: entry)
        context.insert(storedBrew)
        try context.save()
        let jobContext = AIJobRow.Context(beanID: bean.id, beanName: bean.name, style: "hot", cups: 1,
            useGrinder: false, parentRecipeID: original.id, sourceBrewID: entry.id, beanSnapshot: bean)
        let recoveredContext = try JSONDecoder().decode(AIJobRow.Context.self,
            from: JSONEncoder().encode(jobContext))
        let row = AIJobRow(requestID: UUID(), action: "enhanceRecipe", status: "succeeded",
            errorCode: nil, context: recoveredContext, response: "valid", createdAt: Date())
        let store = JobStore()
        store.rows = [row]
        // A failed save must not leave a dangling link on the original brew.
        let failing = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(),
            automaticallyPoll: false, save: { _ in throw TestFailure.unavailable })
        await failing.refresh(context: context)
        #expect(store.acknowledgements == 0)
        #expect(storedBrew.entry?.enhancedRecipeID == nil)
        let recovered = RecipeGenerationCoordinator(cloud: store, gemini: Generator(),
            defaults: defaults(), automaticallyPoll: false)
        await recovered.refresh(context: context)
        let recipe = try #require(context.fetch(FetchDescriptor<StoredRecipe>()).first?.recipe)
        #expect(recipe.id == row.id)
        #expect(recipe.parentRecipeID == original.id)
        #expect(recipe.sourceBrewID == entry.id)
        #expect(recipe.beanID == bean.id)
        #expect(recipe.roaster == bean.roaster)
        #expect(recipe.useGrinder == false)
        #expect(recipe.aiDescription?.contains("What changed and why") == true)
        #expect(storedBrew.entry?.enhancedRecipeID == row.id)
        #expect(storedBrew.entry?.notes == "Too sour")
        #expect(store.acknowledgements == 1)
    }

    @Test func olderDesignContextsStillDecode() throws {
        let data = Data(#"{"beanID":null,"beanName":"Coffee","style":"hot","cups":1,"useGrinder":true}"#.utf8)
        let context = try JSONDecoder().decode(AIJobRow.Context.self, from: data)
        #expect(context.sourceBrewID == nil)
        #expect(context.parentRecipeID == nil)
        #expect(context.beanSnapshot == nil)
    }

    @Test func acknowledgementHappensAfterDurableSaveAndRetryDoesNotDuplicate() async throws {
        let container = try testContainer()
        let context = container.mainContext
        let store = JobStore()
        let row = job()
        store.rows = [row]
        store.acknowledgeFails = true
        store.beforeAcknowledge = { () throws -> Void in
            // A separate context observes only persisted data.
            let reader = ModelContext(container)
            #expect(try reader.fetchCount(FetchDescriptor<StoredRecipe>()) == 1)
            #expect(try reader.fetchCount(FetchDescriptor<StoredRecipeJobReceipt>()) == 1)
        }
        let coordinator = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        await coordinator.refresh(context: context)
        #expect(coordinator.pending.count == 1)
        store.acknowledgeFails = false
        await coordinator.refresh(context: context)
        #expect(try context.fetchCount(FetchDescriptor<StoredRecipe>()) == 1)
        #expect(try context.fetch(FetchDescriptor<StoredRecipe>()).first?.id == row.id)
        #expect(coordinator.pending.isEmpty)
    }

    @Test func failedLocalSaveKeepsTheJobRecoverable() async throws {
        let container = try testContainer()
        let context = container.mainContext
        let store = JobStore()
        store.rows = [job()]
        let failing = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false,
                                                   save: { _ in throw TestFailure.unavailable })
        await failing.refresh(context: context)
        #expect(store.acknowledgements == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredRecipeJobReceipt>()) == 0)
        let recovered = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        await recovered.refresh(context: context)
        #expect(store.acknowledgements == 1)
        #expect(try context.fetchCount(FetchDescriptor<StoredRecipe>()) == 1)
    }

    @Test func invalidResultsPersistARejectionAndStopPolling() async throws {
        let container = try testContainer()
        let store = JobStore()
        let row = job()
        store.rows = [AIJobRow(requestID: row.id, action: row.action, status: row.status,
                              errorCode: nil, context: row.context, response: "invalid", createdAt: row.createdAt)]
        let coordinator = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        await coordinator.refresh(context: container.mainContext)
        #expect(store.acknowledgements == 1)
        #expect(coordinator.pending.isEmpty)
        #expect(coordinator.lastError != nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRecipe>()) == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<StoredRecipeJobReceipt>()).first?.rejection != nil)
    }

    @Test func receiptPreventsReplayAfterRecipeDeletionAndRelaunch() async throws {
        let container = try testContainer()
        let context = container.mainContext
        let store = JobStore()
        store.rows = [job()]
        store.acknowledgeFails = true
        let first = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        await first.refresh(context: context)
        let recipe = try #require(context.fetch(FetchDescriptor<StoredRecipe>()).first)
        context.delete(recipe)
        try context.save()
        store.acknowledgeFails = false
        let relaunched = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        await relaunched.refresh(context: context)
        #expect(store.acknowledgements == 1)
        #expect(try context.fetchCount(FetchDescriptor<StoredRecipe>()) == 0)
    }

    @Test func overlappingRefreshesSerializeCollection() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [job()]
        let gate = Gate()
        store.fetchGate = gate
        let coordinator = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        let first = Task { await coordinator.refresh(context: container.mainContext) }
        while store.fetches == 0 { await Task.yield() }
        await coordinator.refresh(context: container.mainContext)
        gate.release()
        await first.value
        #expect(store.acknowledgements == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRecipe>()) == 1)
    }

    @Test func cancellationBeforeSubmissionIsRetriedAfterTheRowExists() async throws {
        let container = try testContainer()
        let store = JobStore()
        let generator = Generator()
        let gate = Gate()
        generator.gate = gate
        generator.onSubmitted = { store.rows = [job($0)] }
        let coordinator = RecipeGenerationCoordinator(cloud: store, gemini: generator, defaults: defaults(), automaticallyPoll: false)
        let id = coordinator.start(bean: nil, style: .hot, cups: 1, goals: [], notes: "", context: container.mainContext)
        while generator.startedID == nil { await Task.yield() }
        coordinator.cancel(id)
        await coordinator.refresh(context: container.mainContext)
        gate.release()
        for _ in 0..<100 { await Task.yield() }
        await coordinator.refresh(context: container.mainContext)
        #expect(store.rows.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRecipe>()) == 0)
    }

    @Test func offlineCancellationSurvivesRelaunch() async throws {
        let container = try testContainer()
        let store = JobStore()
        let row = job(status: "started")
        store.rows = [row]
        let prefs = defaults()
        let first = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: prefs, automaticallyPoll: false)
        await first.refresh(context: container.mainContext)
        store.cancelFails = true
        first.cancel(row.id)
        await first.refresh(context: container.mainContext)
        store.rows = [job(row.id)]
        let relaunched = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: prefs, automaticallyPoll: false)
        await relaunched.refresh(context: container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRecipe>()) == 0)
        store.cancelFails = false
        await relaunched.refresh(context: container.mainContext)
        #expect(store.rows.isEmpty)
    }

    @Test func disappearingRemoteJobsAndSignOutClearPendingCards() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [job(status: "started")]
        let coordinator = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        await coordinator.refresh(context: container.mainContext)
        #expect(coordinator.pending.count == 1)
        store.rows = [] // Another device collected it.
        await coordinator.refresh(context: container.mainContext)
        #expect(coordinator.pending.isEmpty)
        store.rows = [job(status: "started")]
        await coordinator.refresh(context: container.mainContext)
        store.userID = nil
        coordinator.accountChanged()
        #expect(coordinator.pending.isEmpty)
    }

    @Test func accountChangeDuringFetchDoesNotCollectPreviousUsersResult() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [job()]
        let gate = Gate()
        store.fetchGate = gate
        let coordinator = RecipeGenerationCoordinator(cloud: store, gemini: Generator(), defaults: defaults(), automaticallyPoll: false)
        let refresh = Task { await coordinator.refresh(context: container.mainContext) }
        while store.fetches == 0 { await Task.yield() }
        store.userID = UUID()
        coordinator.accountChanged()
        gate.release()
        await refresh.value
        #expect(store.acknowledgements == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRecipe>()) == 0)
    }
}


private func beanJob(_ id: UUID = UUID(), status: String = "succeeded", response: String = "valid") -> AIJobRow {
    AIJobRow(requestID: id, action: "importBean", status: status, errorCode: nil,
        context: .init(beanID: nil, beanName: "Bag photos", style: "hot", cups: 1,
                       useGrinder: false, photoCount: 2), response: response, createdAt: Date())
}

@Suite(.serialized)
@MainActor
struct BeanImportJobTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "bean-jobs-test-\(UUID())")! }

    @Test func savedBeanAndReceiptSurviveReopeningTheDiskStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("beans.store")
        func openStore() throws -> ModelContainer {
            try ModelContainer(for: StoredBean.self, StoredRecipeJobReceipt.self,
                               configurations: ModelConfiguration(url: url))
        }
        let store = JobStore()
        let id = UUID()
        store.rows = [beanJob(id)]
        store.acknowledgeFails = true
        do {
            let firstLaunch = try openStore()
            let coordinator = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                                   defaults: defaults(), automaticallyPoll: false)
            await coordinator.refresh(context: firstLaunch.mainContext)
            #expect(try firstLaunch.mainContext.fetchCount(FetchDescriptor<StoredBean>()) == 1)
        }
        store.acknowledgeFails = false
        let secondLaunch = try openStore()
        let recovered = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                             defaults: defaults(), automaticallyPoll: false)
        await recovered.refresh(context: secondLaunch.mainContext)
        let beans = try secondLaunch.mainContext.fetch(FetchDescriptor<StoredBean>())
        #expect(beans.count == 1)
        #expect(beans.first?.id == id)
        #expect(recovered.lastImported == nil) // Existing receipt prevented replay.
        #expect(store.rows.isEmpty)
    }

    @Test func relaunchRecoversBeanAndReceiptBeforeAcknowledgement() async throws {
        let container = try testContainer()
        let store = JobStore()
        let generator = Generator()
        let row = beanJob()
        store.rows = [row, job()]
        store.beforeAcknowledge = {
            let beans = try container.mainContext.fetch(FetchDescriptor<StoredBean>())
            #expect(beans.count == 1)
            #expect(beans.first?.id == row.id)
            #expect(beans.first?.needsVerification == true)
            #expect(beans.first?.profile?.roastDate != nil)
            #expect(beans.first?.profile?.process == "") // Unknown label facts are not invented.
            #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRecipeJobReceipt>()) == 1)
        }
        // A new coordinator has no photos, no pending task and no in-memory request IDs.
        let relaunched = BeanImportCoordinator(cloud: store, gemini: generator,
                                               defaults: defaults(), automaticallyPoll: false)
        await relaunched.refresh(context: container.mainContext)
        #expect(relaunched.lastImported?.id == row.id)
        #expect(store.rows.count == 1)
        #expect(store.rows.first?.action == "generateRecipe")
        #expect(relaunched.pending.isEmpty)
    }

    @Test func failedAcknowledgementAndDeletedBeanDoNotReplayAfterRelaunch() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [beanJob()]
        store.acknowledgeFails = true
        let coordinator = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                               defaults: defaults(), automaticallyPoll: false)
        await coordinator.refresh(context: container.mainContext)
        #expect(coordinator.pending.count == 1)
        let bean = try #require(container.mainContext.fetch(FetchDescriptor<StoredBean>()).first)
        container.mainContext.delete(bean)
        try container.mainContext.save()
        store.acknowledgeFails = false
        let relaunched = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                               defaults: defaults(), automaticallyPoll: false)
        await relaunched.refresh(context: container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredBean>()) == 0)
        #expect(store.rows.isEmpty)
    }

    @Test func failedLocalSaveKeepsServerResultRecoverable() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [beanJob()]
        let coordinator = BeanImportCoordinator(cloud: store, gemini: Generator(),
            defaults: defaults(), automaticallyPoll: false, save: { _ in throw TestFailure.unavailable })
        await coordinator.refresh(context: container.mainContext)
        #expect(store.acknowledgements == 0)
        #expect(store.rows.count == 1)
        let relaunched = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                               defaults: defaults(), automaticallyPoll: false)
        await relaunched.refresh(context: container.mainContext)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredBean>()) == 1)
        #expect(store.rows.isEmpty)
    }

    @Test func importsAndRecipesRecoverOnlyTheirOwnCards() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [beanJob(status: "started"), job(status: "started")]
        let beans = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                         defaults: defaults(), automaticallyPoll: false)
        let recipes = RecipeGenerationCoordinator(cloud: store, gemini: Generator(),
                                                  defaults: defaults(), automaticallyPoll: false)
        await beans.refresh(context: container.mainContext)
        await recipes.refresh(context: container.mainContext)
        #expect(beans.pending.count == 1)
        #expect(beans.pending.first?.photoCount == 2)
        #expect(beans.pending.first?.serverAccepted == true)
        #expect(!beans.isUploading(store.rows[0].id))
        #expect(recipes.pending.count == 1)
        #expect(recipes.pending.first?.id == store.rows[1].id)
    }

    @Test func cancelDuringUploadSurvivesRelaunch() async throws {
        let container = try testContainer()
        let store = JobStore()
        let generator = Generator()
        let gate = Gate()
        generator.gate = gate
        let prefs = defaults()
        let coordinator = BeanImportCoordinator(cloud: store, gemini: generator,
                                               defaults: prefs, automaticallyPoll: false)
        let id = try #require(coordinator.start(images: [(Data([1]), "image/jpeg")],
                                                context: container.mainContext))
        #expect(coordinator.isUploading(id))
        #expect(coordinator.pending.first?.serverAccepted == false)
        while generator.startedID == nil { await Task.yield() }
        #expect(generator.enhancementContext?.photoCount == 1)
        store.cancelFails = true
        coordinator.cancel(id)
        generator.onSubmitted = { store.rows = [beanJob($0)] }
        gate.release()
        for _ in 0..<100 { await Task.yield() }
        let relaunched = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                               defaults: prefs, automaticallyPoll: false)
        store.cancelFails = false
        await relaunched.refresh(context: container.mainContext)
        #expect(store.rows.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredBean>()) == 0)
    }

    @Test func invalidImportIsAcknowledgedWithoutCreatingBag() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [beanJob(response: "invalid")]
        let coordinator = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                               defaults: defaults(), automaticallyPoll: false)
        await coordinator.refresh(context: container.mainContext)
        #expect(coordinator.lastError != nil)
        #expect(store.rows.isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredBean>()) == 0)
    }

    @Test func accountSwitchDuringRecoveryDoesNotImportPreviousUsersBag() async throws {
        let container = try testContainer()
        let store = JobStore()
        store.rows = [beanJob()]
        let gate = Gate()
        store.fetchGate = gate
        let coordinator = BeanImportCoordinator(cloud: store, gemini: Generator(),
                                               defaults: defaults(), automaticallyPoll: false)
        let refresh = Task { await coordinator.refresh(context: container.mainContext) }
        while store.fetches == 0 { await Task.yield() }
        store.userID = UUID()
        coordinator.accountChanged()
        gate.release()
        await refresh.value
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredBean>()) == 0)
        #expect(store.acknowledgements == 0)
        #expect(coordinator.pending.isEmpty)
    }
}


@Suite
struct AIJobDateCompatibilityTests {
    @Test func legacySnapshotCannotBlockCompletedBeanAndRecipeJobs() throws {
        let roastDate = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let bean = BeanProfile(name: "Synthetic label", roastDate: roastDate)
        let snapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bean))
        let context: [String: Any] = ["beanName": "Synthetic label", "style": "hot", "cups": 1,
                                     "useGrinder": true, "beanSnapshot": snapshot]
        let rows: [[String: Any]] = [
            ["request_id": UUID().uuidString, "action": "enhanceRecipe", "status": "failed",
             "context": context, "created_at": "2026-09-10T05:24:08.158053+00:00"],
            ["request_id": UUID().uuidString, "action": "importBean", "status": "succeeded",
             "created_at": "2026-09-13T16:44:18.625591+00:00", "response": "synthetic"],
            ["request_id": UUID().uuidString, "action": "generateRecipe", "status": "succeeded",
             "created_at": "2026-09-13T15:44:04+00:00", "response": "synthetic"],
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)
        #expect(throws: DecodingError.self) {
            try PostgrestClient.Configuration.jsonDecoder.decode([AIJobRow].self, from: data)
        }
        let decoded = try AIJobRow.decodeRows(data)
        #expect(decoded.count == 3)
        #expect(decoded.first?.context?.beanSnapshot?.roastDate == roastDate)
        #expect(decoded[1].action == "importBean")
        #expect(decoded[2].status == "succeeded")
    }

    @Test func modernISOSnapshotAndFractionalDatabaseTimestampsDecodeTogether() throws {
        let bean = BeanProfile(name: "Synthetic label", roastDate: Date(timeIntervalSince1970: 1_789_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let context = AIJobRow.Context(beanID: nil, beanName: bean.name, style: "hot", cups: 1,
                                       useGrinder: true, beanSnapshot: bean)
        let row: [String: Any] = ["request_id": UUID().uuidString, "action": "enhanceRecipe",
            "status": "succeeded", "context": try JSONSerialization.jsonObject(with: encoder.encode(context)),
            "created_at": "2026-09-13T16:44:18.625591+00:00"]
        let decoded = try AIJobRow.decodeRows(JSONSerialization.data(withJSONObject: [row]))
        #expect(decoded.first?.context?.beanSnapshot?.roastDate == bean.roastDate)
    }
}
