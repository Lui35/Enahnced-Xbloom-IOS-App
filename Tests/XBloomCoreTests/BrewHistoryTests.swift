import Foundation
import Testing
@testable import XBloomCore

private func sampleBrew(at date: Date, simulated: Bool = false) -> BrewHistoryEntry {
    var recipe = RecipeLibrary.defaults[0]
    recipe.dose = 18
    recipe.useGrinder = true
    return BrewHistoryEntry(recipeID: recipe.id, recipeName: "Test", beanID: nil, beanName: nil,
                            completedAt: date, duration: 120, water: 270, coffeeWeight: 240,
                            steps: recipe.pours.count, recipeSnapshot: recipe, wasSimulated: simulated)
}

@Test func maintenanceCountsFirstBrewAndExcludesSimulations() {
    let first = Date(timeIntervalSince1970: 1_000)
    let usage = Maintenance.usage(brews: [sampleBrew(at: first), sampleBrew(at: first, simulated: true)], servicedAt: nil)
    #expect(usage.brews == 1)
    #expect(usage.groundGrams == 18)
    #expect(usage.since == first)
}

@Test func recordedServiceOnlyCountsSubsequentUse() {
    let service = Date(timeIntervalSince1970: 10_000)
    let usage = Maintenance.usage(brews: [sampleBrew(at: service.addingTimeInterval(-1)),
        sampleBrew(at: service), sampleBrew(at: service.addingTimeInterval(1))], servicedAt: service)
    #expect(usage.brews == 1)
    #expect(usage.groundGrams == 18)
    #expect(usage.wasServiced)
}

@Test func olderHistoryDoesNotInventCompletedPourCounts() throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(sampleBrew(at: Date()))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "outcome")
    object.removeValue(forKey: "completedSteps")
    let decoded = try JSONDecoder().decode(BrewHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.outcome == nil)
    #expect(decoded.completedSteps == nil)
    #expect(decoded.recipeSnapshot != nil)
}
