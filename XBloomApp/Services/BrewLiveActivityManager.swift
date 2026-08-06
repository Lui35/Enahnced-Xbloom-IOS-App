@preconcurrency import ActivityKit
import Foundation
import XBloomCore

@MainActor
final class BrewLiveActivityManager {
    static let shared = BrewLiveActivityManager()

    private var activity: Activity<BrewActivityAttributes>?
    private var lastUpdateAt = Date.distantPast
    private var lastPhase: BrewProgramPhase?
    private var lastPour = -1

    private init() {}

    func resumeExisting() async {
        guard let existing = Activity<BrewActivityAttributes>.activities.first else { return }
        activity = existing
        lastUpdateAt = .distantPast
        lastPhase = existing.content.state.phase
        lastPour = existing.content.state.currentPour
    }

    func endSimulationActivities() async {
        for existing in Activity<BrewActivityAttributes>.activities
        where existing.attributes.machineName == "Brew preview" {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        if activity?.attributes.machineName == "Brew preview" {
            activity = nil
            resetUpdateTracking()
        }
    }

    func start(recipe: Recipe, machineName: String, initialState: BrewActivityAttributes.ContentState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        for existing in Activity<BrewActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = BrewActivityAttributes(
            recipeName: recipe.name,
            machineName: machineName,
            brewStyle: recipe.brewStyle,
            dose: recipe.dose
        )
        let content = ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(45))

        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            lastUpdateAt = .now
            lastPhase = initialState.phase
            lastPour = initialState.currentPour
        } catch {
            // A disabled or unavailable Live Activity must never interrupt a brew.
            activity = nil
        }
    }

    func update(_ state: BrewActivityAttributes.ContentState, force: Bool = false) async {
        guard let activity else { return }
        let isStageChange = state.phase != lastPhase || state.currentPour != lastPour
        guard force || isStageChange || Date().timeIntervalSince(lastUpdateAt) >= 1 else { return }

        await activity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(45))
        )
        lastUpdateAt = .now
        lastPhase = state.phase
        lastPour = state.currentPour
    }

    func end(with finalState: BrewActivityAttributes.ContentState, success: Bool) async {
        guard let activity else { return }
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: success ? .after(Date().addingTimeInterval(90)) : .default
        )
        self.activity = nil
        resetUpdateTracking()
    }

    private func resetUpdateTracking() {
        lastUpdateAt = .distantPast
        lastPhase = nil
        lastPour = -1
    }
}
