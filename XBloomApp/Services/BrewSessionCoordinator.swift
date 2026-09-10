import Foundation
import Observation
import XBloomCore

// UserDefaults is documented as thread-safe, but does not currently conform
// to Sendable. This narrow wrapper lets the persistence actor own all async
// writes while the main actor retains synchronous restoration reads.
private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

enum BrewSessionMode: String, Codable, Identifiable {
    case live
    case simulation

    var id: String { rawValue }
}

@MainActor
@Observable
final class BrewSessionCoordinator {
    struct Presentation: Codable, Identifiable, Equatable, Sendable {
        var id: UUID
        var recipe: Recipe
        var mode: BrewSessionMode
        var startedAt: Date?
        var weightBaseline: Double?
        var waterBaseline: Double?
        var water: Double?
        var weight: Double?
        var temperature: Double?
        var activePourIndex: Int?
        var currentPhase: BrewProgramPhase?
        var samples: [BrewSample]?
        var extractionStartedAt: Date?
        var extractionElapsed: TimeInterval?

        var isResume: Bool {
            mode == .live && startedAt != nil
        }
    }

    private(set) var presentation: Presentation?

    private let defaults: UserDefaults
    private let persistenceStore: BrewSessionPersistenceStore
    private let persistenceKey = "xbloom.activeLiveBrew"
    private let maximumRestorationAge: TimeInterval = 60 * 45
    @ObservationIgnored private var lastSnapshotWriteAt = Date.distantPast
    @ObservationIgnored private var persistenceRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        persistenceStore = BrewSessionPersistenceStore(
            defaults: SendableUserDefaults(defaults),
            key: "xbloom.activeLiveBrew"
        )
        guard
            let data = defaults.data(forKey: persistenceKey),
            let saved = try? JSONDecoder().decode(Presentation.self, from: data),
            saved.mode == .live,
            let startedAt = saved.startedAt,
            Date().timeIntervalSince(startedAt) < maximumRestorationAge
        else {
            defaults.removeObject(forKey: persistenceKey)
            return
        }
        presentation = saved
    }

    func present(recipe: Recipe, mode: BrewSessionMode) {
        presentation = Presentation(
            id: UUID(),
            recipe: recipe,
            mode: mode,
            startedAt: nil,
            weightBaseline: nil,
            waterBaseline: nil,
            water: nil,
            weight: nil,
            temperature: nil,
            activePourIndex: nil,
            currentPhase: nil,
            samples: nil,
            extractionStartedAt: nil,
            extractionElapsed: nil
        )
    }

    func markStarted(at date: Date, weightBaseline: Double?, waterBaseline: Double?) {
        guard var current = presentation, current.mode == .live else { return }
        current.startedAt = date
        current.weightBaseline = weightBaseline
        current.waterBaseline = waterBaseline
        presentation = current
        persist(current)
    }

    func updateSnapshot(
        waterBaseline: Double?,
        water: Double,
        weight: Double,
        temperature: Double?,
        activePourIndex: Int,
        currentPhase: BrewProgramPhase,
        samples: [BrewSample],
        extractionStartedAt: Date?,
        extractionElapsed: TimeInterval
    ) {
        guard var current = presentation, current.mode == .live, current.startedAt != nil else { return }
        guard Date().timeIntervalSince(lastSnapshotWriteAt) >= 4 else { return }
        lastSnapshotWriteAt = Date()
        current.waterBaseline = waterBaseline
        current.water = water
        current.weight = weight
        current.temperature = temperature
        current.activePourIndex = activePourIndex
        current.currentPhase = currentPhase
        // Restoration only needs a compact recent trace. The completed history
        // keeps the complete bounded sample set separately.
        current.samples = Array(samples.suffix(240))
        current.extractionStartedAt = extractionStartedAt
        current.extractionElapsed = extractionElapsed
        persist(current)
    }

    func markCompleted() {
        persistenceRevision += 1
        defaults.removeObject(forKey: persistenceKey)
        let revision = persistenceRevision
        Task { await persistenceStore.clear(revision: revision) }
    }

    /// Closes the live view while the machine carries on brewing.
    ///
    /// Reachable only when the machine is unreachable, because stopping it is
    /// otherwise the single way out of a running brew. The saved snapshot is
    /// deliberately left in place, so reopening the app finds the session still
    /// running and offers to pick it back up. Ending the session outright is
    /// `dismiss()`.
    func detach() {
        guard let current = presentation, current.mode == .live, current.startedAt != nil else {
            dismiss()
            return
        }
        presentation = nil
    }

    func dismiss() {
        let dismissedMode = presentation?.mode
        presentation = nil
        persistenceRevision += 1
        defaults.removeObject(forKey: persistenceKey)
        let revision = persistenceRevision
        Task { await persistenceStore.clear(revision: revision) }
        if dismissedMode == .simulation {
            Task { await BrewLiveActivityManager.shared.endSimulationActivities() }
        }
    }

    private func persist(_ presentation: Presentation) {
        persistenceRevision += 1
        let revision = persistenceRevision
        Task { await persistenceStore.save(presentation, revision: revision) }
    }
}

private actor BrewSessionPersistenceStore {
    private let defaults: SendableUserDefaults
    private let key: String
    private var latestRevision = 0

    init(defaults: SendableUserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func save(_ presentation: BrewSessionCoordinator.Presentation, revision: Int) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(presentation) else { return }
        defaults.value.set(data, forKey: key)
    }

    func clear(revision: Int) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        defaults.value.removeObject(forKey: key)
    }
}
