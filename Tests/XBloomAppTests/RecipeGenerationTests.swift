import Foundation
import SwiftData
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
private final class Generator: RecipeJobGenerating {
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
