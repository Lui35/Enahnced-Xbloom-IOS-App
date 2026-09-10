import Charts
import Observation
import SwiftData
import SwiftUI
import XBloomCore

extension BrewSessionView {
    @MainActor
    func launchSession() async {
        guard !hasStarted else { return }
        hasStarted = true

        if mode == .live, let resumedAt {
            startedAt = resumedAt
            elapsed = max(0, Date().timeIntervalSince(resumedAt))
            weightBaseline = restoredWeightBaseline
            waterBaseline = restoredWaterBaseline
            water = restoredWater ?? 0
            weight = restoredWeight ?? 0
            waterTracker.restore(delivered: water, baseline: restoredWaterBaseline)
            weightTracker.restore(yield: weight, baseline: restoredWeightBaseline)
            temperature = restoredTemperature
            activePourIndex = restoredActivePourIndex ?? 0
            currentPhase = restoredPhase ?? .preparing
            samples = restoredSamples ?? []
            lastSampleAt = samples.last?.elapsed ?? -.infinity
            refreshChartIfNeeded(force: true)
            extractionStartedAt = restoredExtractionStartedAt
            extractionElapsed = restoredExtractionElapsed ?? 0
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            stage = machine.isConnected ? "Restoring live extraction" : "Reconnecting to active brew"
            await BrewLiveActivityManager.shared.resumeExisting()
            startLiveTicker()
            if machine.isConnected {
                captureTelemetry()
            } else {
                reconnectAttempted = true
                machine.connect(resumingBrew: true)
            }
            return
        }

        let sessionStartedAt = Date()
        startedAt = sessionStartedAt
        if mode == .live {
            weightBaseline = machine.telemetry.weight
            waterBaseline = machine.telemetry.waterVolume
            waterTracker.seedBaseline(waterBaseline, at: sessionStartedAt)
            weightTracker.seedBaseline(weightBaseline)
            brewSession.markStarted(
                at: sessionStartedAt,
                weightBaseline: weightBaseline,
                waterBaseline: waterBaseline
            )
            startLiveTicker()
        }
        await BrewLiveActivityManager.shared.start(
            recipe: recipe,
            machineName: mode == .simulation ? "Brew preview" : machine.machineName,
            initialState: activityState(phase: recipe.useGrinder ? .grinding : .preparing)
        )
        if mode == .simulation {
            await runSimulation()
        } else {
            await runLiveBrew()
        }
    }

    @MainActor
    func runLiveBrew() async {
        guard machine.isConnected else {
            errorMessage = "The xBloom disconnected before the recipe could start."
            stage = "Connection lost"
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .error), success: false)
            return
        }
        stage = recipe.useGrinder ? "Sending grinder program" : "Sending brew program"
        do {
            try await machine.startBrew(recipe)
            adoptMachineProgress()
        } catch XBloomBLEClient.MachineError.noMachineResponse {
            // The execute command may have succeeded even when the expected
            // acknowledgement was missed. Keep observing instead of abandoning
            // a machine that is visibly brewing.
            stage = "Recipe sent · waiting for live telemetry"
        } catch {
            errorMessage = error.localizedDescription
            stage = "Could not start"
            brewSession.markCompleted()
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .error), success: false)
        }
    }

    @MainActor
    func runSimulation() async {
        let previewDuration = simulationWallDuration
        let speed = simulationSpeed
        let previewStartedAt = Date()

        while true {
            guard !Task.isCancelled else { return }
            let previewElapsed = Date().timeIntervalSince(previewStartedAt)
            elapsed = min(estimatedDuration, previewElapsed * speed)
            let estimate = Brewing.estimateProgram(
                recipe: recipe,
                elapsed: elapsed,
                grindingDuration: recipe.useGrinder ? 22 : 0,
                settlingDuration: recipe.useGrinder ? 13 : 15
            )
            water = estimate.water
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
            weight = expectedCupYield * pow(progress, 1.12)
            temperature = activePour?.temperature.doubleValue
            activePourIndex = estimate.stepIndex
            if estimate.phase == .grinding { hasLeftGrinding = false }
            else if currentPhase == .grinding || estimate.phase != .preparing {
                hasLeftGrinding = true
            }
            currentPhase = estimate.phase
            stage = stageTitle(for: estimate.phase)
            extractionElapsed = max(0, elapsed - firstPourProgramStart)
            // The preview charts the same window a live brew does: nothing is
            // plotted until the first pour begins.
            if extractionElapsed > 0 {
                if extractionStartedAt == nil { extractionStartedAt = Date() }
                samples.append(
                    BrewSample(
                        elapsed: extractionElapsed,
                        water: water,
                        coffeeWeight: weight,
                        temperature: temperature
                    )
                )
                refreshChartIfNeeded()
            }
            await BrewLiveActivityManager.shared.update(
                activityState(phase: estimate.phase),
                force: estimate.phase == .complete
            )
            if previewElapsed >= previewDuration || estimate.complete {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        elapsed = estimatedDuration
        extractionElapsed = estimatedExtractionDuration
        brewElapsed = estimatedExtractionDuration
        water = Double(recipe.totalWater)
        weight = expectedCupYield
        progress = 1
        finished = true
        currentPhase = .complete
        stage = "Brew complete"
        await BrewLiveActivityManager.shared.end(with: activityState(phase: .complete), success: true)
        recordCompletedSession(
            telemetry: XBloomTelemetry(
                state: .complete,
                weight: weight,
                temperature: temperature,
                waterVolume: water
            ),
            durationOverride: extractionElapsed,
            wasSimulated: true
        )
    }

    /// Drives the live session on its own clock so the display keeps moving
    /// through a long bloom rest, when the machine sends nothing at all.
    @MainActor
    func startLiveTicker() {
        liveTicker?.cancel()
        liveTicker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, mode == .live, !finished else { return }
                tickLiveSession()
            }
        }
    }

    @MainActor
    func tickLiveSession() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        adoptMachineProgress()
        appendLiveSampleIfNeeded()
        persistSessionSnapshot()
        Task {
            await BrewLiveActivityManager.shared.update(activityState(phase: currentPhase))
        }
        finishIfMachineReportsCompletion()
    }

    /// The store throttles itself, so calling this from the ticker keeps the
    /// restore point current through quiet stretches when the machine sends
    /// nothing — including the moment extraction actually began.
    func persistSessionSnapshot() {
        brewSession.updateSnapshot(
            waterBaseline: waterBaseline,
            water: water,
            weight: weight,
            temperature: temperature,
            activePourIndex: activePourIndex,
            currentPhase: currentPhase,
            samples: samples,
            extractionStartedAt: extractionStartedAt,
            extractionElapsed: extractionElapsed
        )
    }

    func captureTelemetry() {
        guard let startedAt, !finished else { return }
        elapsed = Date().timeIntervalSince(startedAt)

        if machine.telemetry.state == .disconnected {
            stage = liveStageTitle
            if !reconnectAttempted {
                reconnectAttempted = true
                machine.connect(resumingBrew: true)
            }
            return
        }

        let readingTime = Date()
        if let rawWater = machine.telemetry.waterVolume {
            let previous = water
            water = waterTracker.ingest(rawValue: rawWater, at: readingTime)
            if water > previous + 0.05 { lastWaterIncreaseAt = readingTime }
        }
        waterBaseline = waterTracker.currentBaseline
        if let rawWeight = machine.telemetry.weight {
            weight = weightTracker.ingest(rawValue: rawWeight, at: readingTime)
            weightBaseline = weightTracker.currentBaseline
        }
        if let rawTemperature = machine.telemetry.temperature,
           rawTemperature.isFinite,
           (0...110).contains(rawTemperature) {
            temperature = rawTemperature
        }

        adoptMachineProgress()
        appendLiveSampleIfNeeded(force: machine.brewProgress.completedAt != nil)
        persistSessionSnapshot()
        Task {
            await BrewLiveActivityManager.shared.update(
                activityState(phase: currentPhase),
                force: currentPhase == .complete
            )
        }

        if machine.telemetry.state == .error,
           errorMessage == nil,
           acknowledgedFault != machine.brewProgress.errorCommand {
            errorMessage = machineErrorMessage
        }


        finishIfMachineReportsCompletion()
    }

    /// Folds the machine's reported lifecycle into the session's own state.
    /// Everything here only ever moves forward, so a dropped connection or a
    /// missed notification cannot rewind the pour count or the clock.
    @MainActor
    func adoptMachineProgress() {
        guard mode == .live, !finished else { return }
        let machineProgress = machine.brewProgress

        // Extraction begins when the machine reports its first watering phase.
        // Water starting to move is kept as a fallback for firmware that does
        // not send that event, which otherwise left the session in preparation
        // right through a pour.
        if extractionStartedAt == nil {
            if let machineStart = machineProgress.extractionStartedAt {
                extractionStartedAt = machineStart
            } else if water > 0.5 {
                extractionStartedAt = Date()
            }
            if extractionStartedAt != nil {
                lastSampleAt = -.infinity
                // Zero the scale on the cup as it stands now. The session
                // baseline was taken before grinding, when the cup was not
                // necessarily on the machine yet — so anything put in place
                // during preparation counted as coffee.
                weightTracker.rebaselineAtExtractionStart()
                weight = weightTracker.yield
                weightBaseline = weightTracker.currentBaseline
            }
        }

        if let extractionStartedAt {
            extractionElapsed = machineElapsed(since: extractionStartedAt)
            // The machine names the pour it is on in every watering-phase
            // frame. Delivered water is only a fallback for firmware that
            // does not send them.
            let reportedIndex = machineProgress.hasObservedPourEvents
                ? machineProgress.pourIndex
                : pourIndexFromDeliveredWater
            let resolvedIndex = min(
                max(0, recipe.pours.count - 1),
                max(activePourIndex, reportedIndex)
            )
            if resolvedIndex != activePourIndex {
                // A new pour is starting; give the counter a moment to move
                // before the display calls it a rest.
                lastWaterIncreaseAt = Date()
                activePourIndex = resolvedIndex
            }
            progress = recipe.totalWater > 0 ? min(1, water / Double(recipe.totalWater)) : 0
        } else {
            // Grinding is preparation, not pour time.
            extractionElapsed = 0
            activePourIndex = 0
            progress = 0
        }

        currentPhase = resolvedLivePhase
        // Keep the "sending the program" message until the machine answers,
        // rather than replacing it with a phase nothing has confirmed yet.
        if machine.brewProgress.lastEventAt != nil || !machine.isSendingRecipe {
            stage = liveStageTitle
        }
    }

    /// True once the machine is on the recipe's last pour and has delivered
    /// essentially all of its water.
    var finalPourDelivered: Bool {
        guard !recipe.pours.isEmpty else { return true }
        guard activePourIndex >= recipe.pours.count - 1 else { return false }
        let target = Double(recipe.totalWater)
        return target <= 0 || water >= target * 0.95
    }

    /// A backstop for firmware that neither reports a finish event nor changes
    /// its screen. Only fires after the last pour is fully delivered and the
    /// counter has been still far longer than any rest in the recipe.
    var hasDrainedAfterFinalPour: Bool {
        guard finalPourDelivered, let lastWaterIncreaseAt else { return false }
        let longestRest = recipe.pours.map { Double($0.pauseAfter) }.max() ?? 0
        return Date().timeIntervalSince(lastWaterIncreaseAt) > max(45, longestRest + 20)
    }

    @MainActor
    func finishIfMachineReportsCompletion() {
        guard !finished, !recordedCompletion else { return }
        // A completion signal before any pour has happened belongs to the
        // machine's previous cycle, not to this brew. Honouring it ended the
        // session seconds after it started, with every pour marked done.
        guard extractionStartedAt != nil else { return }
        let reason: String
        if machine.brewProgress.completedAt != nil {
            reason = "machine reported completion"
        } else if machine.telemetry.state == .complete {
            reason = "telemetry state is complete"
        } else if hasDrainedAfterFinalPour {
            reason = "bed drained after the final pour"
        } else {
            return
        }
        completeLiveSession(reason: reason)
    }

    @MainActor
    func pauseLiveBrew() {
        do {
            try machine.pauseBrew()
            pausedAt = Date()
            withAnimation(.snappy(duration: 0.22)) { isPaused = true }
            stage = "Paused"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func resumeLiveBrew() {
        do {
            try machine.resumeBrew()
            if let pausedAt { pausedTotal += max(0, Date().timeIntervalSince(pausedAt)) }
            pausedAt = nil
            withAnimation(.snappy(duration: 0.22)) { isPaused = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func completeLiveSession(reason: String = "unspecified") {
        machine.noteSessionEvent("App ended the session · \(reason)")
        liveTicker?.cancel()
        liveTicker = nil
        let endedAt = machine.brewProgress.completedAt ?? Date()
        if let extractionStartedAt {
            extractionElapsed = machineElapsed(since: extractionStartedAt, at: endedAt)
        }
        brewElapsed = brewingStartedAt.map { machineElapsed(since: $0, at: endedAt) } ?? extractionElapsed
        finished = true
        progress = 1
        currentPhase = .complete
        stage = "Brew complete"
        appendLiveSampleIfNeeded(force: true)
        brewSession.markCompleted()
        Task {
            await BrewLiveActivityManager.shared.end(with: activityState(phase: .complete), success: true)
        }
        recordCompletedSession(
            telemetry: machine.telemetry,
            durationOverride: brewElapsed
        )
    }

    @MainActor
    func recordCompletedSession(
        telemetry: XBloomTelemetry,
        durationOverride: TimeInterval? = nil,
        wasSimulated: Bool = false,
        outcome: BrewOutcome = .completed
    ) {
        guard !recordedCompletion, let startedAt else { return }
        let bean = storedBeans.first { $0.id == recipe.beanID }
        // History must store the session-relative values shown in the UI, not
        // the machine's raw lifetime counters or the scale's tare baseline.
        let sessionTelemetry = XBloomTelemetry(
            state: telemetry.state,
            weight: weight,
            temperature: temperature,
            waterVolume: water,
            waterLevelOK: telemetry.waterLevelOK,
            lastCommand: telemetry.lastCommand
        )
        do {
            try LocalLibrary.recordCompletedBrew(
                id: sessionID,
                recipe: recipe,
                bean: bean,
                startedAt: startedAt,
                telemetry: sessionTelemetry,
                samples: samples,
                durationOverride: durationOverride,
                wasSimulated: wasSimulated,
                outcome: outcome,
                completedSteps: outcome == .completed ? recipe.pours.count : nil,
                in: modelContext
            )
            recordedCompletion = true
            let id = sessionID
            savedBrew = try modelContext.fetch(FetchDescriptor<StoredBrew>(predicate: #Predicate { $0.id == id })).first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Samples are timestamped from the first pour, never from the moment the
    /// recipe was sent, so the curve and the recipe markers describe the same
    /// clock and nothing is plotted while the machine is still grinding.
    func appendLiveSampleIfNeeded(force: Bool = false) {
        guard extractionStartedAt != nil else { return }
        guard force || extractionElapsed - lastSampleAt >= 0.25 else { return }
        lastSampleAt = extractionElapsed
        samples.append(
            BrewSample(
                elapsed: extractionElapsed,
                water: water,
                coffeeWeight: weight,
                temperature: temperature
            )
        )
        refreshChartIfNeeded(force: force)

        // Four readings per second retain smooth history while the chart uses
        // a cached two-Hz, 120-point representation.
        if samples.count > 2_400 {
            samples.removeFirst(200)
        }
    }

    var pourIndexFromDeliveredWater: Int {
        var cumulative = 0.0
        for (index, pour) in recipe.pours.enumerated() {
            cumulative += Double(pour.volume)
            if water <= cumulative { return index }
        }
        return max(0, recipe.pours.count - 1)
    }

    var resolvedLivePhase: BrewProgramPhase {
        if finished { return .complete }
        if machine.telemetry.state == .error { return .error }
        let machinePhase = machine.brewProgress.phase
        guard extractionStartedAt != nil else { return machinePhase }

        // Extraction has already begun. A reconnect clears the machine-side
        // tracker, so never fall back to a preparation phase the brew has left.
        switch machinePhase {
        case .preparing, .grinding:
            return activePourIndex == 0 ? .blooming : .pouring
        case .blooming, .pouring:
            // The machine says when a pour starts but not when it ends. Once
            // the poured-volume counter stops climbing, the bed is draining.
            return isWaterFlowing ? machinePhase : .resting
        default:
            return machinePhase
        }
    }

    /// Names the fault where the machine names it. An empty grinder is by far
    /// the most likely one on a recipe that grinds, and "check the machine"
    /// does not help you work that out.
    /// Faults the machine names, and which of them should interrupt you.
    ///
    /// A low tank is reported by a machine that carries on brewing regardless,
    /// and the one time it was captured it arrived mid-pour with a zero
    /// payload. It belongs in a banner, not in an alert that stops the session.
    var machineErrorMessage: String? {
        let command = machine.brewProgress.errorCommand
        switch XBloomNotification(rawValue: command ?? 0) {
        case .grinderEmptyAbnormal:
            return recipe.useGrinder
                ? "The grinder found no beans. Put your dose into the grinder, then start the recipe again."
                : "The grinder reported no beans, but this recipe does not grind. Check the machine before retrying."
        case .waterTankVolumeLow:
            return nil
        default:
            if let existing = machine.lastError { return existing }
            // Naming the identifier makes a one-off fault identifiable next
            // time instead of an unreproducible "machine error".
            let identifier = command.map { " (report \($0))" } ?? ""
            return "The xBloom reported a fault\(identifier). The app kept your extraction record; "
                + "check the machine display before stopping anything. Settings › Machine diagnostics "
                + "records the exact frames if it happens again."
        }
    }

    /// Shown inline while the brew carries on, rather than interrupting it.
    var machineWarning: String? {
        guard XBloomNotification(rawValue: machine.brewProgress.errorCommand ?? 0) == .waterTankVolumeLow
        else { return nil }
        return "The machine reported the water tank running low."
    }

    var isWaterFlowing: Bool {
        guard let lastWaterIncreaseAt else { return true }
        return Date().timeIntervalSince(lastWaterIncreaseAt) < 2.5
    }

    var liveStageTitle: String {
        if finished { return "Brew complete" }
        switch machine.connectionState {
        case .disconnected, .unavailable:
            return "Live brew continues · reconnect to monitor"
        case .scanning, .connecting, .subscribing:
            return "Reconnecting to active brew"
        case .connected:
            return stageTitle(for: currentPhase)
        }
    }

    func stageTitle(for phase: BrewProgramPhase) -> String {
        switch phase {
        case .preparing: hasGroundBeans ? "Getting ready to pour" : "Preparing brewer"
        case .grinding: "Grinding beans"
        case .blooming: "Blooming"
        case .pouring: "Pour \(activePourIndex + 1)"
        case .resting: activePourIndex == 0 ? "Bloom rest" : "Rest after pour \(activePourIndex + 1)"
        case .complete: "Brew complete"
        case .error: "Machine needs attention"
        }
    }

    var phaseIcon: String {
        if finished { return "checkmark" }
        return switch currentPhase {
        case .preparing: hasGroundBeans ? "arrow.down.to.line" : "cup.and.saucer.fill"
        case .grinding: "circle.grid.cross.fill"
        case .blooming: "drop.circle.fill"
        case .pouring: "water.waves"
        case .resting: "pause.fill"
        case .complete: "checkmark"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var phaseTint: Color {
        return switch currentPhase {
        case .grinding: StudioTheme.crema
        case .blooming, .pouring: StudioTheme.accent
        case .resting: StudioTheme.muted
        case .complete: StudioTheme.mint
        case .error: StudioTheme.danger
        case .preparing: StudioTheme.muted
        }
    }

    /// True once the beans are ground and the machine is working towards the
    /// first pour.
    var hasGroundBeans: Bool {
        if mode == .live { return machine.brewProgress.grinderFinishedAt != nil }
        return hasLeftGrinding
    }

    /// Zero on the brew clock: the moment the machine reached its brewing
    /// screen, which is where its own display starts counting.
    ///
    /// This used to be the `8002` echo — the recipe being accepted. On a
    /// grinder-off recipe the two are a second apart, but a grinding recipe
    /// spends the whole grind on screens 30 and 34 before it pours, and the app
    /// counted every one of those seconds. `BrewProgressTracker` falls back to
    /// the pre-pour vibration and then to the first pour for firmware that does
    /// not report its screen.
    ///
    /// ponytail: anchored on the pour rather than on the program. If the
    /// machine's own display turns out to count the grind too, move this back
    /// to `recipeAcceptedAt` — it is this one line.
    var brewingStartedAt: Date? {
        guard mode == .live else { return nil }
        return machine.brewProgress.brewingScreenAt ?? extractionStartedAt
    }

    /// Wall time since `start`, less every second the recipe spent paused.
    func machineElapsed(since start: Date, at now: Date = Date()) -> TimeInterval {
        let paused = pausedTotal + (pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        return max(0, now.timeIntervalSince(start) - paused)
    }

    /// What the machine's own display reads. Kept separate from
    /// `extractionElapsed`, which is the chart's zero and has to stay on the
    /// first pour so the recipe markers line up with the data.

    var preparationDetail: String {
        return switch currentPhase {
        case .grinding: "Grinding \(Int(recipe.dose.rounded())) g at \(recipe.rpm.rawValue) RPM"
        case .resting: "Letting the coffee bed drain before the next pour"
        case .error: "Check the machine display before restarting"
        default: mode == .live
            ? "Waiting for the machine to start · pours have not begun"
            : "Preparing the simulated machine workflow"
        }
    }

    func activityState(phase: BrewProgramPhase) -> BrewActivityAttributes.ContentState {
        let currentPour = [.blooming, .pouring, .resting].contains(phase) ? activePourIndex + 1 : 0
        return BrewActivityAttributes.ContentState(
            phase: phase,
            stageTitle: mode == .live && phase == currentPhase ? liveStageTitle : stageTitle(for: phase),
            progress: progress,
            currentPour: currentPour,
            totalPours: recipe.pours.count,
            waterML: water,
            targetWaterML: recipe.totalWater,
            coffeeWeight: weight,
            temperature: temperature,
            elapsedSeconds: Int(extractionElapsed.rounded()),
            remainingSeconds: max(0, Int((estimatedExtractionDuration - extractionElapsed).rounded()))
        )
    }

    func stopLiveBrew() {
        do {
            try machine.stopBrew()
            liveTicker?.cancel()
            liveTicker = nil
            stage = "Brew stopped"
            finished = true
            // A stopped brew is still a finished session: clear the restore
            // snapshot so the next launch does not resurrect it, and keep the
            // partial extraction in history.
            brewSession.markCompleted()
            Task {
                await BrewLiveActivityManager.shared.end(
                    with: activityState(phase: .error),
                    success: false
                )
            }
            recordCompletedSession(
                telemetry: machine.telemetry,
                durationOverride: extractionElapsed,
                outcome: .stopped
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func patternTitle(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Center pour"
        case .circular: "Circular pour"
        case .spiral: "Spiral pour"
        }
    }

}

extension Int {
    var doubleValue: Double { Double(self) }
}
