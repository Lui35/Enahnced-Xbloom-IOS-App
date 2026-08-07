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

    // The dose travels with the bypass command whether or not the grinder runs.
    // Sending zero reads as an invalid dose and the recipe never starts.
    let bypassDose = UInt32(packets[0][18])
        | UInt32(packets[0][19]) << 8
        | UInt32(packets[0][20]) << 16
        | UInt32(packets[0][21]) << 24
    #expect(bypassDose == UInt32(recipe.dose.rounded(.towardZero)))
}

@Test func recipeFooterClampsWaterInsteadOfWrappingThroughTheByte() throws {
    let recipe = Recipe(
        name: "Large batch",
        dose: 20,
        pours: [
            PourStep(volume: 100, temperature: 93, flowRate: 3),
            PourStep(volume: 100, temperature: 93, flowRate: 3),
            PourStep(volume: 100, temperature: 93, flowRate: 3),
        ]
    )
    #expect(recipe.totalWater == 300)

    let payload = try XBloomProtocol.recipePayload(for: recipe)
    // Truncating 300 through the one-byte footer declared 44 ml to the machine.
    #expect(payload[payload.count - 1] == 250)
}

@Test func trafficLogSummarisesWhatTheMachineActuallySent() {
    var log = MachineTrafficLog()
    let start = Date(timeIntervalSince1970: 6_000)
    log.startRecording(at: start)

    log.record(direction: .received, command: 9003, detail: "", payload: Data(), at: start.addingTimeInterval(1))
    log.record(direction: .received, command: 40523, detail: "", payload: Data(), at: start.addingTimeInterval(4))
    log.record(direction: .received, command: 40523, detail: "", payload: Data(), at: start.addingTimeInterval(5))
    log.record(direction: .sent, command: 8002, detail: "", payload: Data(), at: start.addingTimeInterval(6))
    log.record(direction: .received, command: 61234, detail: "", payload: Data(), at: start.addingTimeInterval(7))

    let summary = log.receivedCommandSummary()
    #expect(summary.map(\.command) == [9003, 40523, 61234])
    #expect(summary[1].count == 2)
    #expect(summary[0].firstOffset == 1)

    // An identifier outside the reference has to stand out rather than be
    // silently discarded, since those are the ones worth investigating.
    let unknown = MachineTrafficEntry(
        timestamp: start,
        direction: .received,
        command: 61234,
        detail: "",
        payloadHex: ""
    )
    #expect(unknown.commandName == "unknown(61234)")
    #expect(log.transcript().contains("unknown(61234)"))
}

@Test func trafficLogIgnoresFramesWhileNotRecording() {
    var log = MachineTrafficLog()
    log.record(direction: .received, command: 9003, detail: "", payload: Data())
    #expect(log.entries.isEmpty)

    log.startRecording()
    log.record(direction: .received, command: 9003, detail: "", payload: Data())
    log.stopRecording()
    log.record(direction: .received, command: 9005, detail: "", payload: Data())

    #expect(log.receivedCommandSummary().map(\.command) == [9003])
}

@Test func everyCommandTheAppSendsExistsInTheVendorCommandSet() {
    // The scale-vibrate pair this test used to cover (2502 / 2505) is absent
    // from the official app's table, so the machine had no reason to answer the
    // one probe whose whole job was to prove the link works.
    for command in [
        XBloomCommand.outGrinderPage, .outBrewerPage, .recipeSendAuto, .recipeExecute,
        .recipeSendManual, .setBypass, .setCup, .recipeStop, .deviceCurrentPage,
        .deviceNoSleep, .inScalePage, .outScalePage, .weightCleared,
        .inGrinderPage, .grinderSize, .grinderSpeed, .grindBegin, .grindEnd,
    ] {
        #expect(XBloomNotification(rawValue: command.rawValue) != nil)
    }

    let probe = XBloomProtocol.command(.deviceCurrentPage)
    #expect(UInt16(probe[3]) | UInt16(probe[4]) << 8 == 8023)
}

@Test func notificationFramerSurvivesFragmentedAndConcatenatedPackets() {
    let first = XBloomProtocol.command(.deviceCurrentPage)
    let second = XBloomProtocol.command(.deviceNoSleep)
    var framer = XBloomNotificationFramer()

    #expect(framer.ingest(Data(first.prefix(7))).isEmpty)
    let tailFromNonZeroBasedSlice = first.dropFirst(7)
    #expect(framer.ingest(Data(tailFromNonZeroBasedSlice)) == [first])

    var combined = Data([0xFF, 0xAA])
    combined.append(second)
    combined.append(first)
    #expect(framer.ingest(combined) == [second, first])
}

@Test func pouredVolumeIsReportedInMicroliters() {
    // Verified against a recorded 45 + 95 + 100 ml brew: the counter plateaued
    // at exactly 45000 after the bloom and 140000 after the second pour.
    #expect(XBloomProtocol.pouredMilliliters(fromMicroliters: 45_000) == 45)
    #expect(XBloomProtocol.pouredMilliliters(fromMicroliters: 140_000) == 140)
    #expect(XBloomProtocol.pouredMilliliters(fromMicroliters: 387.5) == 0.3875)
    #expect(XBloomProtocol.pouredMilliliters(fromMicroliters: 0) == 0)
    #expect(XBloomProtocol.pouredMilliliters(fromMicroliters: 5_000_000) == nil)
    #expect(XBloomProtocol.pouredMilliliters(fromMicroliters: .infinity) == nil)
    #expect(XBloomProtocol.pouredMilliliters(fromMicroliters: -1) == nil)
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

@Test func brewProgressStartsExtractionAtTheFirstWateringPhase() {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 1_000)

    // Recipe accepted. Nothing has been poured yet.
    tracker.ingest(command: 40502, value: 0, at: start)
    #expect(tracker.phase == .heating)
    #expect(!tracker.isExtracting)

    tracker.ingest(command: 8023, value: 35, at: start.addingTimeInterval(0.4))
    #expect(tracker.brewingPage == 35)
    #expect(!tracker.isExtracting)

    let firstPour = start.addingTimeInterval(1)
    tracker.ingest(command: 40510, value: 0, at: firstPour)
    #expect(tracker.phase == .blooming)
    #expect(tracker.extractionStartedAt == firstPour)
    #expect(tracker.pourIndex == 0)
    #expect(tracker.hasObservedPourEvents)
}

@Test func wateringPhasePayloadNamesThePourThatIsStarting() {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 2_000)

    tracker.ingest(command: 40510, value: 0, at: start)
    #expect(tracker.pourIndex == 0)
    #expect(tracker.phase == .blooming)

    tracker.ingest(command: 40510, value: 1, at: start.addingTimeInterval(57))
    #expect(tracker.pourIndex == 1)
    #expect(tracker.phase == .pouring)

    // A repeated or out-of-order frame must not rewind the display.
    tracker.ingest(command: 40510, value: 0, at: start.addingTimeInterval(58))
    #expect(tracker.pourIndex == 1)

    tracker.ingest(command: 40510, value: 2, at: start.addingTimeInterval(120))
    #expect(tracker.pourIndex == 2)
}

@Test func leavingTheBrewingScreenCompletesARecipeThatSendsNoFinishEvent() {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 3_000)

    tracker.ingest(command: 40502, value: 0, at: start)
    tracker.ingest(command: 8023, value: 35, at: start.addingTimeInterval(0.4))
    tracker.ingest(command: 40510, value: 0, at: start.addingTimeInterval(1))
    #expect(tracker.completedAt == nil)

    let finish = start.addingTimeInterval(200)
    tracker.ingest(command: 8023, value: 1, at: finish)
    #expect(tracker.completedAt == finish)
    #expect(tracker.phase == .complete)
}

@Test func aZeroWaterTankReportDoesNotInterruptARunningBrew() throws {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 4_000)
    tracker.ingest(command: 40510, value: 0, at: start)

    // Seen mid-brew in a recording while the machine kept pouring normally.
    tracker.ingest(command: 40522, value: 0, at: start.addingTimeInterval(60))
    #expect(tracker.phase == .blooming)
    #expect(tracker.errorCommand == nil)

    tracker.ingest(command: 40522, value: 1, at: start.addingTimeInterval(70))
    #expect(tracker.phase == .error)
    #expect(tracker.errorCommand == 40522)
}

@Test func measurementFramesNeverMoveTheBrewLifecycle() {
    var tracker = BrewProgressTracker()
    let start = Date(timeIntervalSince1970: 5_000)
    tracker.ingest(command: 40510, value: 0, at: start)
    let afterFirstPour = tracker

    for offset in stride(from: 1.0, to: 20.0, by: 0.2) {
        tracker.ingest(command: 40523, value: 42_000, at: start.addingTimeInterval(offset))
        tracker.ingest(command: 20501, value: 12, at: start.addingTimeInterval(offset))
    }
    #expect(tracker == afterFirstPour)
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

/// Replays the lifecycle frames from a real recorded brew — a grinder-off
/// 45 + 95 + 100 ml recipe — in their original order and timing.
@Test func recordedBrewDrivesTheLifecycleCorrectly() {
    var tracker = BrewProgressTracker()
    let origin = Date(timeIntervalSince1970: 10_000)
    func at(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    // Idle telemetry before the recipe is sent must not start anything.
    for offset in stride(from: 0.0, to: 8.0, by: 0.2) {
        tracker.ingest(command: 40523, value: 0, at: at(offset))
        tracker.ingest(command: 20501, value: 0, at: at(offset))
    }
    #expect(tracker.phase == .preparing)
    #expect(!tracker.isExtracting)

    tracker.ingest(command: 8102, value: 0, at: at(8.86))   // bypass ack
    tracker.ingest(command: 8104, value: 0, at: at(9.87))   // pod type ack
    tracker.ingest(command: 8004, value: 0, at: at(10.91))  // recipe ack
    tracker.ingest(command: 8002, value: 0, at: at(11.96))  // marking ack
    tracker.ingest(command: 40502, value: 0, at: at(11.99)) // brewer start
    #expect(tracker.phase == .heating)
    #expect(!tracker.isExtracting)

    tracker.ingest(command: 8023, value: 35, at: at(12.39)) // brewing screen
    #expect(tracker.brewingPage == 35)

    tracker.ingest(command: 40510, value: 0, at: at(12.98)) // first pour
    #expect(tracker.phase == .blooming)
    #expect(tracker.pourIndex == 0)
    #expect(tracker.extractionStartedAt == at(12.98))

    // The bloom and the long rest that follows it: measurement frames only.
    for offset in stride(from: 13.0, to: 69.4, by: 0.2) {
        tracker.ingest(command: 40523, value: 45_000, at: at(offset))
        tracker.ingest(command: 20501, value: 0, at: at(offset))
    }
    // A zero water-tank report arrives mid-brew and must not interrupt it.
    tracker.ingest(command: 40522, value: 0, at: at(72.53))
    #expect(tracker.pourIndex == 0)
    #expect(tracker.errorCommand == nil)

    tracker.ingest(command: 40510, value: 1, at: at(69.43)) // second pour
    #expect(tracker.phase == .pouring)
    #expect(tracker.pourIndex == 1)
    #expect(tracker.completedAt == nil)

    tracker.ingest(command: 40519, value: 0, at: at(108.88)) // stop ack
    #expect(tracker.completedAt == nil)

    tracker.ingest(command: 8023, value: 1, at: at(109.32))  // back to home
    #expect(tracker.completedAt == at(109.32))
    #expect(tracker.phase == .complete)
}

/// The counter values from the same recording, decoded through the parser.
@Test func recordedWaterCounterMatchesTheRecipeVolumes() {
    let bloomPlateau = XBloomProtocol.pouredMilliliters(fromMicroliters: 45_000)
    let secondPourPlateau = XBloomProtocol.pouredMilliliters(fromMicroliters: 140_000)
    let firstMovement = XBloomProtocol.pouredMilliliters(fromMicroliters: 387.5)

    #expect(bloomPlateau == 45)          // recipe pour 1
    #expect(secondPourPlateau == 140)    // pours 1 + 2
    #expect(firstMovement == 0.3875)     // sub-millilitre, not 387 ml

    // Two consecutive readings 0.28 s apart differ by 775 microlitres, which is
    // the recipe's 3.0 ml/s flow. Anything that turned these into hundreds of
    // millilitres was reading the counter at the wrong scale.
    let a = XBloomProtocol.pouredMilliliters(fromMicroliters: 1_162.5) ?? 0
    let b = XBloomProtocol.pouredMilliliters(fromMicroliters: 1_937.5) ?? 0
    #expect(((b - a) / 0.28 - 2.77).magnitude < 0.1)
}

@Test func manualPourTravelsTheVerifiedRecipeEncoding() throws {
    let pour = ManualPour(
        volume: 60,
        temperature: 92,
        flowRate: 3.2,
        pattern: .circular,
        agitation: true
    )
    #expect(pour.validate().isEmpty)

    let recipe = pour.asRecipe
    #expect(!recipe.useGrinder)
    #expect(recipe.pours.count == 1)
    #expect(recipe.totalWater == 60)
    // The bypass dose must not be zero; a grinder-off program with a zero dose
    // is suspected of being rejected outright.
    #expect(recipe.dose > 0)
    try RecipeValidator.requireSafe(recipe)

    let packets = try XBloomProtocol.brewSequence(for: recipe)
    let commandIDs = packets.map { UInt16($0[3]) | UInt16($0[4]) << 8 }
    #expect(commandIDs == [8102, 8104, 8004, 8002])

    let payload = try XBloomProtocol.recipePayload(for: recipe)
    #expect(payload[0] == 8)                 // one pour, eight bytes
    #expect(payload[1] == 60)                // volume
    #expect(payload[2] == 92)                // temperature
    #expect(payload[3] == UInt8(PourPattern.circular.rawValue))
    #expect(payload[4] == 1)                 // agitate before only
    #expect(payload[8] == 32)                // flow 3.2 ml/s
}

@Test func manualPourRejectsSettingsOutsideTheMachineLimits() {
    #expect(ManualPour(volume: 400).validate().contains { $0.field == "volume" })
    #expect(ManualPour(temperature: 120).validate().contains { $0.field == "temperature" })
    #expect(ManualPour(flowRate: 9).validate().contains { $0.field == "flowRate" })
    #expect(ManualPour().validate().isEmpty)
}

@Test func grinderProgressIsSurfacedRawAndNeverAsGrams() throws {
    var payload = Data(count: 4)
    payload[0] = 0x2A
    let frame = XBloomProtocol.rawCommand(.recipeStop, payload: payload)
    var grinderDoing = frame
    grinderDoing[3] = 0x3A          // 40506 grinder_doing
    grinderDoing[4] = 0x9E
    let crc = XBloomProtocol.crc16(grinderDoing.dropLast(2))
    grinderDoing[grinderDoing.count - 2] = UInt8(crc & 0xFF)
    grinderDoing[grinderDoing.count - 1] = UInt8(crc >> 8)

    let telemetry = try XBloomProtocol.parseNotification(grinderDoing)
    #expect(telemetry.grinderReport == 42)
    #expect(telemetry.state == .grinding)
    // Nothing pretends this is a weight.
    #expect(telemetry.weight == nil)
}

@Test func grindGuideCoversTheWholeDialWithoutGapsOrOverlaps() {
    let bands = GrindSizeGuide.bands
    #expect(bands.first?.range.lowerBound == GrindSizeGuide.fullRange.lowerBound)
    #expect(bands.last?.range.upperBound == GrindSizeGuide.fullRange.upperBound)

    for (previous, next) in zip(bands, bands.dropFirst()) {
        #expect(next.range.lowerBound == previous.range.upperBound + 1)
    }

    // Every setting the dial can reach names exactly one method.
    for size in GrindSizeGuide.fullRange {
        let matches = bands.filter { $0.range.contains(size) }
        #expect(matches.count == 1)
    }
}

@Test func grindGuideNamesTheExpectedMethods() {
    #expect(GrindSizeGuide.method(for: 1) == "Espresso")
    #expect(GrindSizeGuide.method(for: 15) == "Espresso")
    #expect(GrindSizeGuide.method(for: 16) == "AeroPress")
    #expect(GrindSizeGuide.method(for: 30) == "AeroPress")
    #expect(GrindSizeGuide.method(for: 31) == "Pour-over")
    #expect(GrindSizeGuide.method(for: 55) == "Pour-over")
    #expect(GrindSizeGuide.method(for: 56) == "French press")
    #expect(GrindSizeGuide.method(for: 80) == "French press")

    // Out-of-range values clamp rather than crashing or returning nothing.
    #expect(GrindSizeGuide.method(for: 0) == "Espresso")
    #expect(GrindSizeGuide.method(for: 500) == "French press")
}
