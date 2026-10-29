import Testing
@testable import XBloomCore

@Test func restCountdownTracksTheNextPourAcrossBothPauseFields() {
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = false
    recipe.pours = Array(recipe.pours.prefix(2))
    recipe.pours[0].pauseBefore = 5
    recipe.pours[0].volume = 30
    recipe.pours[0].flowRate = 3
    recipe.pours[0].pauseAfter = 10
    recipe.pours[1].pauseBefore = 4
    recipe.pours[1].pauseAfter = 6
    func estimate(_ seconds: Double) -> BrewProgramEstimate {
        Brewing.estimateProgram(recipe: recipe, elapsed: seconds, settlingDuration: 0)
    }
    #expect(estimate(2).rest?.nextPourIndex == 0)
    #expect(estimate(2).rest?.completedPourIndex == nil)
    #expect(estimate(2).rest?.remainingSeconds == 3)
    #expect(estimate(5).phase == .blooming)
    #expect(estimate(5).rest == nil)
    #expect(estimate(15).rest?.completedPourIndex == 0)
    #expect(estimate(15).rest?.nextPourIndex == 1)
    #expect(estimate(15).rest?.remainingSeconds == 14)
    #expect(estimate(24.5).rest?.remainingSeconds == 5)
    #expect(estimate(25).rest?.remainingSeconds == 4)
    #expect(estimate(29).phase == .pouring)
    #expect(estimate(29).rest == nil)
    let finalRest = 29 + Double(recipe.pours[1].volume) / recipe.pours[1].flowRate
    #expect(estimate(finalRest).rest?.nextPourIndex == nil)
    #expect(estimate(finalRest).rest?.remainingSeconds == 6)
    #expect(estimate(finalRest + 6).phase == .complete)
    #expect(estimate(finalRest + 6).rest == nil)
}

@Test func liveRestCountdownRoundsUpAndStopsAtZero() {
    let recipe = RecipeLibrary.defaults[0]
    #expect(BrewRest(recipe: recipe, completedPourIndex: 0, remaining: 9.2).remainingSeconds == 10)
    #expect(BrewRest(recipe: recipe, completedPourIndex: 0, remaining: -2).remainingSeconds == 0)
    #expect(BrewRest(recipe: recipe, completedPourIndex: recipe.pours.count - 1, remaining: 2).nextPourIndex == nil)
}
