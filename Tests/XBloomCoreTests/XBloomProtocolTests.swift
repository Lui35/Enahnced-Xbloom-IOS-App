import Foundation
import Testing
@testable import XBloomCore

@Test func commandMatchesPyBloomFrameShape() {
    let packet = XBloomProtocol.command(.recipeExecute)
    #expect(packet.count == 12)
    #expect(Array(packet.prefix(10)) == [0x58, 0x01, 0x01, 0x42, 0x1F, 0x0C, 0, 0, 0, 1])
    #expect(XBloomProtocol.crc16(packet.dropLast(2)) == UInt16(packet[10]) | UInt16(packet[11]) << 8)
}

@Test func recipePayloadChunksVolumesAt127ML() throws {
    let recipe = Recipe(
        name: "Chunk test",
        grindSize: 50,
        rpm: .rpm80,
        dose: 18,
        pours: [
            PourStep(volume: 200, temperature: 93, flowRate: 3.2, pauseAfter: 30),
            PourStep(volume: 80, temperature: 92, flowRate: 3.5),
        ]
    )
    let payload = try XBloomProtocol.recipePayload(for: recipe)
    #expect(Array(payload[1...8]) == [127, 93, 2, 0, 73, 93, 2, 0])
    #expect(payload[9] == UInt8(truncatingIfNeeded: -30))
    #expect(payload[11] == 80)
    #expect(payload[12] == 32)
}

@Test func validationRejectsUnsafeMachineValues() {
    let recipe = Recipe(
        name: "Unsafe",
        grindSize: 50,
        dose: 18,
        pours: [PourStep(volume: 600, temperature: 110)]
    )
    let errors = RecipeValidator.validate(recipe).filter { $0.severity == .error }
    #expect(errors.contains { $0.field == "water" })
    #expect(errors.contains { $0.field.contains("temperature") })
}

@Test func inventoryDeductionNeverGoesNegative() {
    let bean = BeanProfile(name: "Coffee", initialWeightGrams: 15, remainingWeightGrams: 10)
    let updated = Brewing.deductDose(18, from: bean)
    #expect(updated.remainingWeightGrams == 0)
}

@Test func grindingNeverConsumesTheFirstPourOrItsWaitTime() {
    let recipe = Recipe(
        name: "Sequenced brew",
        dose: 18,
        useGrinder: true,
        pours: [
            PourStep(volume: 45, temperature: 93, flowRate: 3, pauseBefore: 5, pauseAfter: 30),
            PourStep(volume: 105, temperature: 92, flowRate: 3)
        ]
    )

    let duringGrinding = Brewing.estimateProgram(
        recipe: recipe,
        elapsed: 21,
        grindingDuration: 22,
        heatingDuration: 10
    )
    #expect(duringGrinding.phase == .grinding)
    #expect(duringGrinding.water == 0)
    #expect(duringGrinding.extractionElapsed == 0)

    let firstPourWait = Brewing.estimateProgram(
        recipe: recipe,
        elapsed: 22 + 10 + 5 + 15,
        grindingDuration: 22,
        heatingDuration: 10
    )
    #expect(firstPourWait.phase == .resting)
    #expect(firstPourWait.water == 45)
    #expect(firstPourWait.extractionElapsed == 20)
}

@Test func simulationPreviewRunsForAVisibleRealisticAmountOfTime() {
    #expect(Brewing.simulationWallDuration(for: 90) == 60)
    #expect(Brewing.simulationWallDuration(for: 180) == 90)
    #expect(Brewing.simulationWallDuration(for: 300) == 120)
}

@Test func recipeLibraryArchivePreservesCompletePrograms() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.generatedByAI = true
    recipe.aiDescription = "Preserve every portable recipe field."
    recipe.pours[0].pattern = .circular
    recipe.pours[0].agitationBefore = true

    let archive = RecipeLibraryArchive(
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        recipes: [recipe]
    )
    let data = try JSONEncoder().encode(archive)
    let decoded = try JSONDecoder().decode(RecipeLibraryArchive.self, from: data)

    #expect(decoded.schemaVersion == RecipeLibraryArchive.currentSchemaVersion)
    #expect(decoded.recipes == [recipe])
}

@Test func extractionTimelineKeepsPreparationAndRestBoundariesSeparate() throws {
    let recipe = Recipe(
        name: "Timeline",
        useGrinder: true,
        pours: [
            PourStep(volume: 45, temperature: 93, flowRate: 3, pauseBefore: 5, pauseAfter: 30),
            PourStep(volume: 90, temperature: 91, flowRate: 3, pauseAfter: 0),
        ]
    )
    let events = Brewing.timelineEvents(recipe: recipe, grindingDuration: 22, heatingDuration: 13)

    #expect(events.count == 3)
    #expect(events[0].title == "Bloom")
    #expect(events[0].elapsed == 40)
    #expect(events[1].kind == .rest)
    #expect(events[1].elapsed == 55)
    #expect(events[2].title == "P2")
    #expect(events[2].elapsed == 85)
}

@Test func defaultRecipesRemainMachineSafe() {
    for recipe in RecipeLibrary.defaults {
        #expect(RecipeValidator.validate(recipe).allSatisfy { $0.severity != .error })
    }
}

@Test func icedRatioUsesBrewWaterAndKeepsIceSeparate() {
    let recipe = Recipe(
        name: "Iced concentrate",
        dose: 22,
        brewStyle: .iced,
        iceGrams: 120,
        pours: [
            PourStep(volume: 45, temperature: 92),
            PourStep(volume: 60, temperature: 90),
            PourStep(volume: 60, temperature: 88),
        ]
    )
    #expect(recipe.totalWater == 165)
    #expect(recipe.ratio == 7.5)
    #expect(!RecipeValidator.validate(recipe).contains { $0.field == "ratio" })
}

@Test func brewSequenceUsesTheMachineCommandOrder() throws {
    let recipe = RecipeLibrary.defaults[0]
    let packets = try XBloomProtocol.brewSequence(for: recipe)
    let commandIDs = packets.map { UInt16($0[3]) | UInt16($0[4]) << 8 }
    #expect(commandIDs == [8102, 8104, 8001, 8002])
}

@Test func manualBrewUsesTheNoGrinderRecipeCommand() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = false
    let packets = try XBloomProtocol.brewSequence(for: recipe)
    let commandIDs = packets.map { UInt16($0[3]) | UInt16($0[4]) << 8 }
    #expect(commandIDs == [8102, 8104, 8004, 8002])
}

@Test func machineTestUsesSafeScaleCommands() {
    let vibrate = XBloomProtocol.command(.scaleVibrate)
    let stop = XBloomProtocol.command(.scaleStop)
    #expect(UInt16(vibrate[3]) | UInt16(vibrate[4]) << 8 == 2502)
    #expect(UInt16(stop[3]) | UInt16(stop[4]) << 8 == 2505)
}

@Test func notificationFramerSurvivesFragmentedAndConcatenatedPackets() {
    let first = XBloomProtocol.command(.scaleVibrate)
    let second = XBloomProtocol.command(.scaleStop)
    var framer = XBloomNotificationFramer()

    #expect(framer.ingest(Data(first.prefix(7))).isEmpty)
    let tailFromNonZeroBasedSlice = first.dropFirst(7)
    #expect(framer.ingest(Data(tailFromNonZeroBasedSlice)) == [first])

    var combined = Data([0xFF, 0xAA])
    combined.append(second)
    combined.append(first)
    #expect(framer.ingest(combined) == [second, first])
}

@Test func waterTelemetryIgnoresImpossibleReadingsInsteadOfRescalingThem() {
    #expect(XBloomProtocol.normalizedWaterVolume(150) == 150)
    #expect(XBloomProtocol.normalizedWaterVolume(0) == 0)
    #expect(XBloomProtocol.normalizedWaterVolume(750) == 750)
    // Rescaling used to turn 760 into 76 mid-brew, which collapsed the live
    // figures and latched the display on the pre-collapse value.
    #expect(XBloomProtocol.normalizedWaterVolume(760) == nil)
    #expect(XBloomProtocol.normalizedWaterVolume(1_500_000) == nil)
    #expect(XBloomProtocol.normalizedWaterVolume(.infinity) == nil)
    #expect(XBloomProtocol.normalizedWaterVolume(-1) == nil)
}

@Test func machineInfoReportsTankLevelSeparatelyFromPouredWater() throws {
    var payload = Data(repeating: 0, count: 40)
    payload[33] = 1
    payload[36] = 200

    let frame = XBloomProtocol.rawCommand(.recipeStop, payload: payload)
    var machineInfo = frame
    machineInfo[3] = 0x49
    machineInfo[4] = 0x9E
    let crc = XBloomProtocol.crc16(machineInfo.dropLast(2))
    machineInfo[machineInfo.count - 2] = UInt8(crc & 0xFF)
    machineInfo[machineInfo.count - 1] = UInt8(crc >> 8)

    let telemetry = try XBloomProtocol.parseNotification(machineInfo)
    #expect(telemetry.lastCommand == 40521)
    #expect(telemetry.waterLevelOK == true)
    #expect(telemetry.tankWaterLevel == 200)
    // The reservoir level must never be mistaken for water poured into the cup.
    #expect(telemetry.waterVolume == nil)
}

@Test func extractionTimelineStartsAtTheFirstPour() {
    let recipe = Recipe(
        name: "Extraction zero",
        useGrinder: true,
        pours: [
            PourStep(volume: 45, temperature: 93, flowRate: 3, pauseBefore: 5, pauseAfter: 30),
            PourStep(volume: 90, temperature: 91, flowRate: 3, pauseBefore: 4, pauseAfter: 0),
        ]
    )
    let events = Brewing.extractionEvents(recipe: recipe)

    #expect(events.count == 3)
    #expect(events[0].title == "Bloom")
    #expect(events[0].elapsed == 0)
    #expect(events[1].kind == .rest)
    #expect(events[1].elapsed == 15)
    #expect(events[2].title == "P2")
    #expect(events[2].elapsed == 49)
    // 15 s bloom + 30 s rest + 4 s lead-in + 30 s second pour.
    #expect(Brewing.extractionDuration(recipe: recipe) == 79)
}

@Test func brewProgressStartsExtractionOnlyWhenTheMachineStartsPouring() {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 1_000)

    tracker.ingest(command: 9000, at: start)
    tracker.ingest(command: 9003, at: start.addingTimeInterval(1))
    #expect(tracker.phase == .grinding)
    #expect(tracker.extractionStartedAt == nil)

    tracker.ingest(command: 40507, at: start.addingTimeInterval(20))
    tracker.ingest(command: 9001, at: start.addingTimeInterval(22))
    #expect(tracker.phase == .heating)
    #expect(!tracker.isExtracting)

    let firstPour = start.addingTimeInterval(35)
    tracker.ingest(command: 9005, at: firstPour)
    tracker.ingest(command: 40510, at: firstPour.addingTimeInterval(0.2))
    #expect(tracker.phase == .blooming)
    #expect(tracker.extractionStartedAt == firstPour)
    #expect(tracker.pourIndex == 0)
}

@Test func brewProgressAdvancesOnePourPerPauseAndResume() {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 2_000)

    tracker.ingest(command: 9005, at: start)
    #expect(tracker.pourIndex == 0)

    tracker.ingest(command: 9010, at: start.addingTimeInterval(15))
    #expect(tracker.phase == .resting)
    #expect(tracker.pourIndex == 0)

    tracker.ingest(command: 9005, at: start.addingTimeInterval(45))
    #expect(tracker.phase == .pouring)
    #expect(tracker.pourIndex == 1)

    // Repeated start notifications inside one pour must not skip ahead.
    tracker.ingest(command: 40502, at: start.addingTimeInterval(46))
    #expect(tracker.pourIndex == 1)
}

@Test func brewerStopOnlyCompletesTheRecipeAfterTheFinalPour() {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 3_000)
    tracker.ingest(command: 9005, at: start)
    tracker.ingest(command: 40511, at: start.addingTimeInterval(15))

    tracker.confirmCompletionIfSettled(
        at: start.addingTimeInterval(60),
        finalPourDelivered: false
    )
    #expect(tracker.completedAt == nil)

    // A later start belongs to the next pour, not to a finished recipe.
    tracker.ingest(command: 9005, at: start.addingTimeInterval(45))
    #expect(tracker.pourIndex == 1)
    #expect(tracker.completedAt == nil)

    tracker.ingest(command: 40511, at: start.addingTimeInterval(80))
    tracker.confirmCompletionIfSettled(
        at: start.addingTimeInterval(84),
        finalPourDelivered: true
    )
    #expect(tracker.completedAt == nil)

    tracker.confirmCompletionIfSettled(
        at: start.addingTimeInterval(90),
        finalPourDelivered: true
    )
    #expect(tracker.completedAt == start.addingTimeInterval(90))
    #expect(tracker.phase == .complete)
}

@Test func deliveryTrackerRejectsJumpsFasterThanTheMachineCanPour() {
    var tracker = BrewDeliveryTracker(
        target: 250,
        maximumRate: 3.5,
        allowsCounterReset: true
    )
    let start = Date(timeIntervalSince1970: 4_000)
    tracker.seedBaseline(0, at: start)

    #expect(tracker.ingest(rawValue: 6, at: start.addingTimeInterval(2)) == 6)

    // A reservoir reading misread as poured water used to latch the display at
    // the final pour; it can now only advance at a believable pour rate.
    let afterBogusReading = tracker.ingest(rawValue: 200, at: start.addingTimeInterval(2.5))
    #expect(afterBogusReading < 20)

    // Real readings still catch up rather than being rejected as regressions.
    let recovered = tracker.ingest(rawValue: 40, at: start.addingTimeInterval(14))
    #expect(recovered == 40)
}

@Test func deliveryTrackerRebasesWhenTheMachineZeroesItsCounter() {
    var tracker = BrewDeliveryTracker(
        target: 250,
        maximumRate: 4,
        allowsCounterReset: true
    )
    let start = Date(timeIntervalSince1970: 5_000)
    // The previous brew's total is still on the counter when this one starts.
    tracker.seedBaseline(240, at: start)

    #expect(tracker.ingest(rawValue: 0, at: start.addingTimeInterval(1)) == 0)
    #expect(tracker.ingest(rawValue: 30, at: start.addingTimeInterval(12)) == 30)
}

@Test func olderSavedRecipesDecodeWithoutEnhancementLineage() throws {
    let original = RecipeLibrary.defaults[0]
    let encoded = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "parentRecipeID")
    object.removeValue(forKey: "sourceBrewID")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(Recipe.self, from: legacyData)

    #expect(decoded.id == original.id)
    #expect(decoded.parentRecipeID == nil)
    #expect(decoded.sourceBrewID == nil)
}

@Test func brewHistoryPreservesRecipeBeanFeedbackAndEnhancementLink() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.generatedByAI = true
    let bean = BeanProfile(name: "Linked bean", roaster: "Local roaster")
    recipe.beanID = bean.id
    let enhancedID = UUID()
    let entry = BrewHistoryEntry(
        recipeID: recipe.id,
        recipeName: recipe.name,
        beanID: bean.id,
        beanName: bean.name,
        duration: 180,
        water: 250,
        coffeeWeight: 215,
        steps: recipe.pours.count,
        rating: 3,
        notes: "Sweet, but the finish was dry.",
        recipeSnapshot: recipe,
        beanSnapshot: bean,
        feedbackTags: ["Dry finish", "Needs more body"],
        enhancementGoals: ["Higher clarity", "More sweetness", "Round & smooth"],
        enhancedRecipeID: enhancedID
    )

    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(BrewHistoryEntry.self, from: data)

    #expect(decoded.recipeSnapshot == recipe)
    #expect(decoded.beanSnapshot == bean)
    #expect(decoded.feedbackTags == ["Dry finish", "Needs more body"])
    #expect(decoded.enhancementGoals == ["Higher clarity", "More sweetness", "Round & smooth"])
    #expect(decoded.enhancedRecipeID == enhancedID)
}

@Test func olderBrewHistoryDecodesWithoutSnapshotsOrFeedbackTags() throws {
    let entry = BrewHistoryEntry(
        recipeID: UUID(),
        recipeName: "Legacy brew",
        beanID: nil,
        beanName: nil,
        duration: 150,
        water: 250,
        coffeeWeight: 210,
        steps: 3
    )
    let encoded = try JSONEncoder().encode(entry)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    ["recipeSnapshot", "beanSnapshot", "feedbackTags", "enhancementGoals", "enhancedRecipeID"].forEach {
        object.removeValue(forKey: $0)
    }

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(BrewHistoryEntry.self, from: legacyData)

    #expect(decoded.recipeName == "Legacy brew")
    #expect(decoded.recipeSnapshot == nil)
    #expect(decoded.feedbackTags == nil)
    #expect(decoded.enhancementGoals == nil)
}

@Test func brewGraphSmoothingPreservesRawSamplesAndSoftensWeightJumps() {
    let raw = [
        BrewSample(elapsed: 0, water: 0, coffeeWeight: 0),
        BrewSample(elapsed: 0.25, water: 40, coffeeWeight: 0),
        BrewSample(elapsed: 0.5, water: 40, coffeeWeight: 32),
        BrewSample(elapsed: 0.75, water: 80, coffeeWeight: 31.5),
    ]

    let smoothed = BrewGraphSmoother.smooth(raw)

    #expect(raw[2].coffeeWeight == 32)
    #expect(smoothed.count == raw.count)
    #expect(smoothed[2].coffeeWeight > 0)
    #expect(smoothed[2].coffeeWeight < raw[2].coffeeWeight)
    #expect(smoothed[3].coffeeWeight >= smoothed[2].coffeeWeight)
    #expect(smoothed[3].water >= smoothed[2].water)
}

@Test func flavorGoalsCombineCompatibleChoicesAndReplaceOnlyDirectOpposites() {
    var selected: Set<RecipeFlavorGoal> = []
    selected = RecipeFlavorGoal.toggling(.sweetness, in: selected)
    selected = RecipeFlavorGoal.toggling(.roundness, in: selected)
    selected = RecipeFlavorGoal.toggling(.clarity, in: selected)

    #expect(selected == [.sweetness, .roundness, .clarity])

    selected = RecipeFlavorGoal.toggling(.brightAcidity, in: selected)
    selected = RecipeFlavorGoal.toggling(.lowAcidity, in: selected)

    #expect(!selected.contains(.brightAcidity))
    #expect(selected.contains(.lowAcidity))
    #expect(selected.contains(.sweetness))
    #expect(selected.contains(.roundness))
    #expect(selected.contains(.clarity))
}

@Test func beanAcidityCanRemainUnknownWhenTheBagDoesNotProvideIt() throws {
    let bean = BeanProfile(name: "Mystery acidity")
    #expect(bean.acidityLevel == nil)

    let data = try JSONEncoder().encode(bean)
    let decoded = try JSONDecoder().decode(BeanProfile.self, from: data)
    #expect(decoded.acidityLevel == nil)
}
