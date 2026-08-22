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
        settlingDuration: 10
    )
    #expect(duringGrinding.phase == .grinding)
    #expect(duringGrinding.water == 0)
    #expect(duringGrinding.extractionElapsed == 0)

    let firstPourWait = Brewing.estimateProgram(
        recipe: recipe,
        elapsed: 22 + 10 + 5 + 15,
        grindingDuration: 22,
        settlingDuration: 10
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
    let events = Brewing.timelineEvents(recipe: recipe, grindingDuration: 22, settlingDuration: 13)

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

@Test func recipeFooterCarriesRatioTenthsFromTheVendorCapture() throws {
    let recipe = Recipe(
        name: "Vendor captured iced recipe",
        dose: 22,
        pours: [
            PourStep(volume: 40, temperature: 90, flowRate: 3),
            PourStep(volume: 40, temperature: 90, flowRate: 3),
            PourStep(volume: 40, temperature: 90, flowRate: 3),
            PourStep(volume: 45, temperature: 90, flowRate: 3),
        ]
    )
    #expect(recipe.totalWater == 165)
    #expect(recipe.ratio == 7.5)

    let payload = try XBloomProtocol.recipePayload(for: recipe)
    // The official 165 ml / 22 g recipe ends in 0x4B, decimal 75.
    #expect(payload[payload.count - 1] == 75)
}

@Test func failedDiagnosticRecipeNowEncodesItsRatioInsteadOfItsWater() throws {
    let recipe = Recipe(
        name: "Iced Chelchele Berry & Lychee Flash",
        grindSize: 38,
        rpm: .rpm90,
        dose: 16,
        useGrinder: true,
        pours: [
            PourStep(volume: 45, temperature: 92, flowRate: 3.2),
            PourStep(volume: 55, temperature: 92, flowRate: 3.2),
            PourStep(volume: 50, temperature: 90, flowRate: 3.2),
        ]
    )

    let payload = try XBloomProtocol.recipePayload(for: recipe)
    #expect(recipe.totalWater == 150)
    #expect(payload[payload.count - 1] == 94) // round(150 / 16 * 10)
    #expect(payload[payload.count - 1] != 150) // byte in the failed recording
}

@Test func brewCommandPlanOwnsTheTransportIndependentCadence() throws {
    let plan = try BrewCommandPlan(recipe: RecipeLibrary.defaults[0])
    #expect(plan.steps.map(\.kind) == [.configureDose, .configureCup, .uploadRecipe, .execute])
    #expect(plan.steps.map(\.settleAfter) == [1, 1, 1, 0])
    #expect(plan.steps.map { UInt16($0.packet[3]) | UInt16($0.packet[4]) << 8 } == [8102, 8104, 8001, 8002])
}

@Test func grinderInterlockStopsOnlyWhenWaterActuallyStartsWithoutGrinding() {
    var interlock = BrewGrinderInterlock(requiresGrinding: true)

    // Page 35 caused the previous false stop. It is diagnostic only.
    #expect(interlock.ingest(command: 8023, value: 35) == .observing)
    #expect(interlock.ingest(command: 40502, value: nil) == .observing)
    #expect(interlock.ingest(command: 40510, value: 0) == .stopUnexpectedPour)

    var ground = BrewGrinderInterlock(requiresGrinding: true)
    #expect(ground.ingest(command: 8023, value: 34) == .grindingConfirmed)
    #expect(ground.ingest(command: 40510, value: 0) == .pourAllowed)

    var manual = BrewGrinderInterlock(requiresGrinding: false)
    #expect(manual.ingest(command: 40510, value: 0) == .observing)
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
        .inGrinderPage, .grindAdjust, .grindPause, .grindEnd,
        .recipePause, .recipeResume, .mtuNegotiate,
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
    #expect(tracker.phase == .preparing)
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
    #expect(tracker.phase == .preparing)
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

/// Guards the grinder-on path against the grinder-off work that sits beside it.
@Test func grinderOnRecipesStillCarryEverythingTheGrinderNeeds() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = true
    recipe.grindSize = 55
    recipe.rpm = .rpm70
    recipe.dose = 17

    let packets = try XBloomProtocol.brewSequence(for: recipe)
    let commandIDs = packets.map { UInt16($0[3]) | UInt16($0[4]) << 8 }
    // 8001 is the grind-and-brew program; 8004 would skip the grinder entirely.
    #expect(commandIDs == [8102, 8104, 8001, 8002])

    let bypassDose = UInt32(packets[0][18])
        | UInt32(packets[0][19]) << 8
        | UInt32(packets[0][20]) << 16
        | UInt32(packets[0][21]) << 24
    #expect(bypassDose == 17)

    // The cup pair separates a grinding program from a manual one, and the
    // figures come from the vendor's own frame rather than from invention.
    let cupMinimum = Float(
        bitPattern: UInt32(packets[1][14])
            | UInt32(packets[1][15]) << 8
            | UInt32(packets[1][16]) << 16
            | UInt32(packets[1][17]) << 24
    )
    #expect(cupMinimum == 80)

    let payload = try XBloomProtocol.recipePayload(for: recipe)
    #expect(payload[payload.count - 2] == UInt8(recipe.grindSize))
    // RPM rides in the first pour's metadata block and must not be zero, or the
    // burrs never turn.
    #expect(payload[7] == UInt8(recipe.rpm.rawValue))
    #expect(payload[7] != 0)
}

@Test func aWeighedDoseReplacesTheRecipeTargetWithoutTouchingTheGrinder() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = true
    recipe.dose = 16

    // What DoseWeighingView hands back after the beans are on the scale.
    var brewed = recipe
    brewed.dose = 16.1

    #expect(brewed.useGrinder)
    #expect(brewed.grindSize == recipe.grindSize)
    #expect(brewed.rpm == recipe.rpm)

    let packets = try XBloomProtocol.brewSequence(for: brewed)
    #expect(packets.map { UInt16($0[3]) | UInt16($0[4]) << 8 } == [8102, 8104, 8001, 8002])

    // The bag is debited by what was really weighed, not the rounded target.
    let bean = BeanProfile(name: "Bag", initialWeightGrams: 250, remainingWeightGrams: 100)
    #expect(Brewing.deductDose(brewed.dose, from: bean).remainingWeightGrams == 83.9)
}

/// The weighing sheet holds the machine's scale screen open. Leaving it has to
/// happen before the brew's setup commands, not alongside them.
@Test func theScaleScreenIsGivenBackBeforeABrewAndOnlyOnce() {
    var pages = MachinePages()
    #expect(pages.isEmpty)
    #expect(pages.exitsBeforeBrew.isEmpty)

    pages.scale = true
    #expect(!pages.isEmpty)
    #expect(pages.exitsBeforeBrew == [.outScalePage])

    pages.grinder = true
    // The scale goes first, and neither exit is repeated.
    #expect(pages.exitsBeforeBrew == [.outScalePage, .outGrinderPage])

    // A page the app never opened sends nothing: an unnecessary frame next to a
    // recipe is exactly what broke the grind.
    #expect(MachinePages(grinder: true).exitsBeforeBrew == [.outGrinderPage])
    #expect(MachinePages().exitsBeforeBrew.isEmpty)
}

@Test func aGrindingRecipeNeverSendsAZeroGrinderSpeed() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = true
    recipe.rpm = .off

    // An imported or synced recipe can pair grinding with no speed. The payload
    // byte that turns the burrs must still be a real speed, or 8001 is accepted
    // and the machine pours onto whole beans.
    #expect(recipe.programRPM != .off)
    let payload = try XBloomProtocol.recipePayload(for: recipe)
    #expect(payload[7] == UInt8(recipe.programRPM.rawValue))
    #expect(payload[7] != 0)

    // It is a warning, not a silent repair: the editor says which speed will run.
    let issue = RecipeValidator.validate(recipe).first { $0.field == "rpm" }
    #expect(issue?.severity == .warning)
    // ...and it never blocks the brew.
    try RecipeValidator.requireSafe(recipe)

    // A real speed is passed through untouched.
    recipe.rpm = .rpm110
    #expect(recipe.programRPM == .rpm110)
    #expect(RecipeValidator.validate(recipe).contains { $0.field == "rpm" } == false)

    // A grinder-off recipe keeps the bytes the verified capture recorded.
    recipe.useGrinder = false
    recipe.rpm = .off
    #expect(recipe.programRPM == .off)
}

/// A dose that misses the recipe's target is the normal case, not a fault. The
/// bands say how the cup changes; none of them is a refusal to brew.
@Test func aDoseShortOfTheTargetIsStillABrewableDose() {
    var recipe = RecipeLibrary.defaults[0]
    recipe.brewStyle = .hot
    recipe.dose = 16
    recipe.pours = [PourStep(volume: 250, temperature: 93, flowRate: 3.2)]

    // Nothing weighed yet.
    #expect(DoseFit(measured: 0, recipe: recipe) == .empty)
    #expect(DoseFit(measured: 0.4, recipe: recipe) == .empty)

    // The tenth of a gram the scale resolves to is the target.
    #expect(DoseFit(measured: 16, recipe: recipe) == .onTarget)
    #expect(DoseFit(measured: 15.9, recipe: recipe) == .onTarget)

    // The gram either way a bag realistically lands in.
    #expect(DoseFit(measured: 15.5, recipe: recipe) == .close)
    #expect(DoseFit(measured: 15.0, recipe: recipe) == .close)
    #expect(DoseFit(measured: 16.8, recipe: recipe) == .close)
    #expect(DoseFit(measured: 15.5, recipe: recipe).isNominal)

    // Past a gram the cup is weaker, but 1:17.6 is still a hot pour-over.
    #expect(DoseFit(measured: 14.2, recipe: recipe) == .short)
    // Past the style's ratio range it is a different drink, and says so.
    #expect(DoseFit(measured: 12, recipe: recipe) == .thin)
    // Over cannot be undone, so it is called out either way.
    #expect(DoseFit(measured: 17.5, recipe: recipe) == .over)

    // The dose the machine is given is the weighed one, and the water does not
    // move with it — which is the whole reason a short dose brews weaker.
    #expect(recipe.ratio(atDose: 16) == 250.0 / 16)
    #expect(recipe.ratio(atDose: 15) > recipe.ratio)
    #expect(recipe.ratio(atDose: 0) == 0)

    // Iced is judged against its own, stronger range rather than the hot one.
    var iced = recipe
    iced.brewStyle = .iced
    iced.dose = 20
    iced.pours = [PourStep(volume: 200, temperature: 93, flowRate: 3.2)]
    // 200 ml over 16 g is 1:12.5 — light for an iced brew but still an iced brew.
    #expect(RecipeValidator.recommendedRatio(for: .iced).contains(iced.ratio(atDose: 16)))
    #expect(DoseFit(measured: 16, recipe: iced) == .short)
    // The same 1:16.7 that passes for a hot pour-over does not pass here.
    #expect(DoseFit(measured: 12, recipe: iced) == .thin)
}

/// The scale is a measurement, not a counter. Read through the monotonic
/// delivery tracker, one hand resting on the machine ratcheted the yield above
/// the real weight and every later, correct reading was rejected as a
/// regression — which is why the cup-yield curve stayed flat while water
/// climbed, and why pressing the plate was the only thing that ever moved it.
@Test func aHandOnTheScaleDoesNotBecomeCupYield() {
    var tracker = ScaleYieldTracker(expectedYield: 250, window: 1.0)
    let start = Date()
    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    // An empty cup and dripper are already on the plate.
    tracker.seedBaseline(412)
    #expect(tracker.yield == 0)
    #expect(!tracker.hasMeasuredYield)

    // Coffee arriving: the reading holds its new level, so it counts.
    for step in stride(from: 0.0, through: 6.0, by: 0.2) {
        tracker.ingest(rawValue: 412 + step * 10, at: at(step))
    }
    #expect(tracker.hasMeasuredYield)
    #expect(tracker.yield > 40)
    let beforeThePress = tracker.yield

    // A hand leaning on the machine for half a second, then off again. The
    // real weight on the plate is 60 g; the press reports 860. The tracked
    // value may still be catching up to the 60 it lagged behind, but none of
    // the 800 may reach it.
    for step in stride(from: 6.2, through: 6.6, by: 0.2) {
        tracker.ingest(rawValue: 412 + 60 + 800, at: at(step))
    }
    #expect(tracker.yield >= beforeThePress)
    #expect(tracker.yield <= 60.001)

    // ...and the real weight is still believed afterwards.
    for step in stride(from: 6.8, through: 9.0, by: 0.2) {
        tracker.ingest(rawValue: 412 + 60 + (step - 6.8) * 10, at: at(step))
    }
    #expect(tracker.yield > beforeThePress)

    // Lifting the cup is a real change, not a transient, so it is reported.
    for step in stride(from: 9.2, through: 11.0, by: 0.2) {
        tracker.ingest(rawValue: 0, at: at(step))
    }
    #expect(tracker.yield == 0)
}

/// The session baseline is taken before grinding, when the cup may not be on
/// the machine at all. Whatever is put in place during preparation must not be
/// served as coffee.
@Test func theCupIsZeroedWhenPouringStartsNotWhenTheSessionDoes() {
    var tracker = ScaleYieldTracker(expectedYield: 250, window: 1.0)
    let start = Date()
    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    tracker.seedBaseline(0)
    // The cup and dripper go on during grinding: 380 g that is not coffee.
    for step in stride(from: 0.0, through: 3.0, by: 0.2) {
        tracker.ingest(rawValue: 380, at: at(step))
    }
    #expect(tracker.yield > 300)

    tracker.rebaselineAtExtractionStart()
    #expect(tracker.yield == 0)
    #expect(!tracker.hasMeasuredYield)

    for step in stride(from: 3.2, through: 8.0, by: 0.2) {
        tracker.ingest(rawValue: 380 + (step - 3.2) * 12, at: at(step))
    }
    #expect(tracker.yield > 30)
    #expect(tracker.yield < 60)
}

/// This machine has no heating step. It never sends a heating event and never
/// reports water temperature — 8108 did not appear once in a 1088-frame
/// recording — so the app had invented a state and shown it as a reading.
@Test func thereIsNoHeatingPhaseBetweenTheGrinderAndTheFirstPour() {
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = true

    // Every phase the estimator can produce is one the machine can be in.
    let phases = stride(from: 0.0, through: 400.0, by: 1.0).map {
        Brewing.estimateProgram(recipe: recipe, elapsed: $0).phase
    }
    #expect(!phases.isEmpty)
    #expect(phases.contains(.grinding))
    #expect(phases.contains(.blooming))
    #expect(phases.allSatisfy { $0.rawValue != "heating" })

    // A session saved by a build that still had the phase resumes cleanly.
    let decoded = try? JSONDecoder().decode(BrewProgramPhase.self, from: Data("\"heating\"".utf8))
    #expect(decoded == .preparing)

    // The brew clock starts when the grinder stops. This firmware sends no
    // grinder events, so the first pour has to stand in for it.
    var tracker = BrewProgressTracker()
    let start = Date()
    tracker.ingest(command: XBloomNotification.brewerStart.rawValue, value: nil, at: start)
    #expect(tracker.phase == .preparing)
    #expect(tracker.recipeAcceptedAt == start)
    #expect(tracker.grinderFinishedAt == nil)

    let firstPour = start.addingTimeInterval(24)
    tracker.ingest(command: XBloomNotification.wateringPhase.rawValue, value: 0, at: firstPour)
    #expect(tracker.grinderFinishedAt == firstPour)
    #expect(tracker.extractionStartedAt == firstPour)
    #expect(tracker.phase == .blooming)
}

/// Replays the scale readings from the 2026-08-21 recording of a real iced
/// brew (grinder off, 3 pours, 168 ml, 16 g). The machine streams a perfectly
/// usable curve — 0 g to 155.8 g — with two things in it that broke naive
/// readings: it drops to exactly 0.0 several times during the first pour, and
/// a hand on the machine at t=125 reads 3471.9 g for four frames.
@Test func theRecordedBrewProducesACupYieldCurve() {
    var tracker = ScaleYieldTracker(expectedYield: 136)
    let start = Date()
    func send(_ t: Double, _ grams: Double) {
        tracker.ingest(rawValue: grams, at: start.addingTimeInterval(t))
    }

    // Idle before the first pour.
    for t in stride(from: 0.0, through: 14.4, by: 0.2) { send(t, 0) }
    tracker.rebaselineAtExtractionStart()

    // First pour: the reading climbs but keeps snapping back to zero.
    var t = 14.6
    for grams in [0, 1.1, 1.5, 2.4, 2.9, 3.7, 4.5, 0, 1.3, 2.1, 2.8, 3.8, 4.5, 0, 1.4] as [Double] {
        send(t, grams)
        t += 0.28
    }
    // ...and then climbs for real.
    for grams in stride(from: 2.2, through: 36.9, by: 1.1) {
        send(t, grams)
        t += 0.28
    }
    #expect(tracker.hasMeasuredYield)
    #expect(tracker.yield > 25)

    // The bloom sits at 36.9 g for half a minute.
    while t < 63 { send(t, 36.9); t += 0.2 }
    #expect(abs(tracker.yield - 36.9) < 0.5)

    // Pours two and three.
    for grams in stride(from: 37.0, through: 155.8, by: 1.2) {
        send(t, grams)
        t += 0.2
    }
    while t < 125 { send(t, 155.8); t += 0.2 }
    let beforeThePress = tracker.yield
    #expect(beforeThePress > 150)

    // A hand on the machine: four frames at 3471.9 g, then gone.
    for _ in 0..<4 { send(t, 3471.9); t += 0.2 }
    #expect(abs(tracker.yield - beforeThePress) < 0.5)

    while t < 137 { send(t, 155.8); t += 0.2 }
    #expect(abs(tracker.yield - 155.8) < 0.5)
}

/// The 2026-08-21 recording is the only brew whose yield has actually been
/// weighed: 168 ml over a 16 g dose delivered 155.8 g.
@Test func theYieldEstimateMatchesTheOneBrewThatWasMeasured() {
    var recipe = RecipeLibrary.defaults[0]
    recipe.dose = 16
    recipe.pours = [
        PourStep(volume: 60, temperature: 93, flowRate: 3),
        PourStep(volume: 54, temperature: 93, flowRate: 3),
        PourStep(volume: 54, temperature: 93, flowRate: 3),
    ]
    #expect(recipe.totalWater == 168)
    #expect(abs(recipe.expectedYield - 155.8) < 5)

    // The old 2 g/gram figure was out by four times that.
    #expect(abs((Double(recipe.totalWater) - recipe.dose * 2) - 155.8) > 15)

    // A dose big enough to drink the whole recipe still leaves a usable scale.
    var absurd = recipe
    absurd.dose = 400
    #expect(absurd.expectedYield == 1)
}

/// The machine's clock runs from brewer_start to take_cup. Both timings in the
/// 2026-08-21 10:58 recording are exact: the app was starting one second late
/// on pour_first_vibration_before, and then reporting the finished figure from
/// the first pour, which lost another seven.
@Test func theBrewClockAgreesWithTheMachineDisplay() throws {
    var tracker = BrewProgressTracker()
    let zero = Date()
    func at(_ seconds: Double) -> Date { zero.addingTimeInterval(seconds) }

    tracker.ingest(command: 40502, value: nil, at: at(13.11))   // brewer start
    tracker.ingest(command: 8023, value: 35, at: at(13.51))     // brewing screen
    tracker.ingest(command: 40527, value: nil, at: at(14.11))   // first agitation
    tracker.ingest(command: 40510, value: 0, at: at(21.11))     // pour 1
    tracker.ingest(command: 40510, value: 1, at: at(69.83))     // pour 2
    tracker.ingest(command: 40510, value: 2, at: at(109.84))    // pour 3
    tracker.ingest(command: 40511, value: nil, at: at(129.23))  // watering finish
    tracker.ingest(command: 40512, value: nil, at: at(139.49))  // take cup

    let accepted = try #require(tracker.recipeAcceptedAt)
    let completed = try #require(tracker.completedAt)
    let extraction = try #require(tracker.extractionStartedAt)

    // 2:06 on the machine.
    #expect(Int(completed.timeIntervalSince(accepted).rounded()) == 126)
    // The old figure, measured from the first pour: 1:58.
    #expect(Int(completed.timeIntervalSince(extraction).rounded()) == 118)
    // The agitation event is one second past the machine's zero, which is
    // exactly the gap that showed while the brew was running.
    let agitation = try #require(tracker.grinderFinishedAt)
    #expect(Int(agitation.timeIntervalSince(accepted).rounded()) == 1)

    #expect(tracker.phase == .complete)
    #expect(tracker.pourIndex == 2)
}

/// A recipe that grinds still sends 8001 with a real grind size and speed —
/// nothing about the visual pass or the clock work touched the decision. What
/// was missing is any way to notice the machine ignoring it: it accepts the
/// recipe, skips the burrs, and pours over dry beans without an error.
@Test func aGrindingRecipeThatNeverGroundIsNoticed() throws {
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = true
    recipe.rpm = .rpm80

    let packets = try XBloomProtocol.brewSequence(for: recipe)
    #expect(packets.map { UInt16($0[3]) | UInt16($0[4]) << 8 } == [8102, 8104, 8001, 8002])

    // Grinder off takes the other opcode, and only that.
    var manual = recipe
    manual.useGrinder = false
    let manualPackets = try XBloomProtocol.brewSequence(for: manual)
    #expect(manualPackets.map { UInt16($0[3]) | UInt16($0[4]) << 8 } == [8102, 8104, 8004, 8002])

    // A brew that pours without a single grinder frame.
    var silent = BrewProgressTracker()
    let start = Date()
    silent.ingest(command: 40502, value: nil, at: start)
    silent.ingest(command: 40510, value: 0, at: start.addingTimeInterval(20))
    #expect(silent.isExtracting)
    #expect(!silent.observedGrinding)

    // ...against one where the machine says it ground.
    var ground = BrewProgressTracker()
    ground.ingest(command: 40502, value: nil, at: start)
    ground.ingest(command: 40506, value: 1, at: start.addingTimeInterval(3))   // grinder_doing
    ground.ingest(command: 40507, value: nil, at: start.addingTimeInterval(18)) // grinder_finish
    ground.ingest(command: 40510, value: 0, at: start.addingTimeInterval(20))
    #expect(ground.observedGrinding)
    #expect(ground.grinderFinishedAt == start.addingTimeInterval(18))
}

/// Every frame here was read out of an HCI capture of the vendor's own app on
/// 2026-08-22 — its real writes, not the echoes a second connection can see.
@Test func theVendorsFramesAreReproducedByteForByte() throws {
    func frame(_ command: XBloomCommand, _ values: [UInt32] = []) -> String {
        XBloomProtocol.command(command, values: values).hexString
    }

    // Connect. The machine shows itself as paired after this one.
    #expect(frame(.mtuNegotiate, [185, 1]) == "580101a41f14000000 01b9000000010000 00bdd1".replacingOccurrences(of: " ", with: ""))

    // Pause, resume and stop are bare commands, and already matched.
    #expect(frame(.recipePause) == "58010146 9e0c000000 0180a1".replacingOccurrences(of: " ", with: ""))
    #expect(frame(.recipeResume) == "5801014c9e0c00000001d748")
    #expect(frame(.recipeStop) == "580101479e0c00000001553e")

    // The grinder, which this app had entirely wrong: 8006 carries the setting,
    // 3500 starts the burrs, 8018 stops them, 3505 leaves.
    #expect(frame(.inGrinderPage, [53, 100]) == "58010146 1f1400000001 350000006400 0000c4af".replacingOccurrences(of: " ", with: ""))
    #expect(frame(.grindAdjust, [1000, 53, 100]) == "580101ac0d1800000001e8030000350000006400 0000d863".replacingOccurrences(of: " ", with: ""))
    #expect(frame(.grindPause) == "58010152 1f0c0000 0001b67a".replacingOccurrences(of: " ", with: ""))
    #expect(frame(.grindEnd) == "580101b10d0c00000001a6ba")

    // And the recipe's cup frame, which is why a grinding recipe never ground.
    var recipe = RecipeLibrary.defaults[0]
    recipe.useGrinder = true
    let cup = try XBloomProtocol.brewSequence(for: recipe)[1]
    #expect(cup.hexString.hasPrefix("580101a81f1400000001"))
    #expect(cup.hexString.contains("00004843"))   // 200.0
    #expect(cup.hexString.contains("0000a042"))   // 80.0
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// Replays the 2026-08-22 12:43 recording, where pressing pause ended the
/// session. The machine changes screens when it pauses — page 35 becomes page
/// 31 — and the page backstop read any change away from the brewing screen as
/// a finished cup.
@Test func pausingABrewDoesNotFinishIt() throws {
    var tracker = BrewProgressTracker()
    let zero = Date()
    func at(_ s: Double) -> Date { zero.addingTimeInterval(s) }

    tracker.ingest(command: 40502, value: nil, at: at(7.49))   // brewer start
    tracker.ingest(command: 8023, value: 35, at: at(7.89))     // brewing screen
    tracker.ingest(command: 40510, value: 0, at: at(8.50))     // first pour
    #expect(tracker.isExtracting)

    tracker.ingest(command: 40518, value: nil, at: at(12.67))  // pause echo
    tracker.ingest(command: 40515, value: nil, at: at(12.70))  // brewer_start_stop
    tracker.ingest(command: 8023, value: 31, at: at(13.09))    // screen changes
    #expect(tracker.completedAt == nil)
    #expect(tracker.phase != .complete)

    // Resuming and running on is still a live brew.
    tracker.ingest(command: 40524, value: nil, at: at(20))
    tracker.ingest(command: 8023, value: 35, at: at(21))
    #expect(tracker.completedAt == nil)

    // Going home ends it, which is what a hand-stopped brew does.
    tracker.ingest(command: 8023, value: 1, at: at(60))
    #expect(tracker.completedAt == at(60))
    #expect(tracker.phase == .complete)

    // And take_cup still ends it outright, which is what this firmware sends.
    var natural = BrewProgressTracker()
    natural.ingest(command: 40502, value: nil, at: at(0))
    natural.ingest(command: 8023, value: 35, at: at(1))
    natural.ingest(command: 40510, value: 0, at: at(2))
    natural.ingest(command: 8023, value: 34, at: at(3))   // grinding, mid-brew
    #expect(natural.completedAt == nil)
    natural.ingest(command: 40512, value: nil, at: at(90))
    #expect(natural.completedAt == at(90))
}
