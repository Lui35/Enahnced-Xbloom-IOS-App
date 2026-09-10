import Charts
import Observation
import SwiftData
import SwiftUI
import XBloomCore

extension BrewSessionView {
    func circleControl(
        systemImage: String,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 68, height: 68)
                .background(tint.opacity(0.16), in: Circle())
                .overlay { Circle().stroke(tint.opacity(0.55), lineWidth: 2) }
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    var sessionControls: some View {
        VStack(spacing: 10) {
            if finished {
                Button {
                    brewSession.dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(StudioTheme.mint, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if mode == .simulation {
                Button {
                    brewSession.dismiss()
                } label: {
                    Label("Close preview", systemImage: "xmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(StudioTheme.raised, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if machine.isConnected {
                // Stopping the machine is the only way out of a running brew.
                // Walking away used to be offered beside it, which let the app
                // and the machine disagree about whether coffee was being made
                // — the session closed, the xBloom kept pouring, and nothing on
                // screen said so.
                // Two controls, both circles, one at each margin: a running
                // brew has exactly two things you can do to it and neither
                // needs a word to explain the symbol. The space between them
                // is where the brew says something back.
                HStack(spacing: 12) {
                    circleControl(
                        systemImage: isPaused ? "play.fill" : "pause.fill",
                        tint: StudioTheme.accent,
                        label: isPaused ? "Resume brewing" : "Pause brewing"
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            isPaused ? resumeLiveBrew() : pauseLiveBrew()
                        }
                    }

                    Spacer(minLength: 12)

                    circleControl(
                        systemImage: "stop.fill",
                        tint: StudioTheme.danger,
                        label: "Stop brewing"
                    ) {
                        confirmingStop = true
                    }
                }
                .overlay {
                    if isPaused {
                        Text("Holding — the machine is waiting")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                }
            } else {
                // Nothing can be sent while the link is down, so there is no
                // stop to offer. Reconnecting is the way back to one — but a
                // dropped connection must not lock the app into a session it
                // can no longer control, so closing stays available here and
                // only here, and says plainly what it does not do.
                Button {
                    reconnectAttempted = true
                    machine.connect(resumingBrew: true)
                } label: {
                    Label("Reconnect to stop it", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(StudioTheme.warning, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(
                    machine.connectionState == .scanning
                        || machine.connectionState == .connecting
                        || machine.connectionState == .subscribing
                )

                Button {
                    confirmingLeave = true
                } label: {
                    Label("Close without stopping", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .background(.ultraThinMaterial)
    }

    var extractionHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.raised, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.015, progress))
                    .stroke(finished ? StudioTheme.mint : StudioTheme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.25), value: progress)
                VStack(spacing: 3) {
                    Image(systemName: phaseIcon)
                        .font(.title2.weight(.bold))
                    Text("\(Int(progress * 100))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(finished ? StudioTheme.mint : StudioTheme.accent)
            }
            .frame(width: 132, height: 132)

            Text(stage)
                .font(.title2.weight(.bold))
            Text(
                mode == .simulation
                    ? String(format: "Realistic %.1f× preview · no machine commands", simulationSpeed)
                    : machine.machineName
            )
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    var sessionTiming: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                timingCell(
                    title: finished ? "Completed in" : "Elapsed",
                    value: durationText(
                        finished
                            ? brewElapsed
                            : mode == .simulation
                                ? extractionElapsed
                                : brewingStartedAt.map { machineElapsed(since: $0, at: context.date) } ?? 0
                    ),
                    icon: "timer"
                )
                timingCell(
                    title: mode == .simulation ? "Preview time" : "Estimated",
                    value: durationText(mode == .simulation ? simulationWallDuration : estimatedExtractionDuration),
                    icon: "hourglass"
                )
            }
        }
    }

    func timingCell(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(StudioTheme.muted)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
    }

    var reconnectCard: some View {
        StudioCard(accent: StudioTheme.warning) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Live monitoring disconnected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StudioTheme.warning)
                Text("The xBloom recipe keeps running on the machine. Reconnecting only attaches to telemetry — it will not stop the brew or send the recipe again.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    var preparationCard: some View {
        StudioCard(accent: phaseTint) {
            HStack(spacing: 15) {
                Image(systemName: phaseIcon)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(phaseTint)
                    .frame(width: 58, height: 58)
                    .background(phaseTint.opacity(0.14), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
                // The hero above already names the phase and draws this icon.
                // Repeating "Grinding beans" here made the viewport say it
                // three times; the card's job is the detail underneath it.
                VStack(alignment: .leading, spacing: 5) {
                    Text(preparationDetail)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ProgressView()
                    .tint(phaseTint)
            }
        }
    }

    func activePourCard(_ pour: PourStep) -> some View {
        StudioCard(accent: StudioTheme.accent) {
            HStack(spacing: 15) {
                PourPatternMark(pattern: pour.pattern, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(activePourIndex == 0 ? "Bloom" : "Pour \(activePourIndex + 1)")
                        .font(.title3.weight(.bold))
                    Text("\(pour.volume) ml · \(pour.temperature)°C · \(String(format: "%.1f", pour.flowRate)) ml/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioTheme.muted)
                    Text(patternTitle(pour.pattern))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.accent)
                }
                Spacer()
                if pour.agitationBefore || pour.agitationAfter {
                    AgitationTimingMarks(
                        before: pour.agitationBefore,
                        after: pour.agitationAfter,
                        size: 29
                    )
                }
            }
        }
    }

    var extractionChart: some View {
        StudioCard(accent: StudioTheme.mint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(StudioTheme.mint)
                        .frame(width: 36, height: 36)
                        .background(
                            StudioTheme.mint.opacity(0.13),
                            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Extraction curve")
                            .font(.headline.weight(.bold))
                        Text(
                            extractionStartedAt == nil
                                ? "Begins when the machine starts the first pour"
                                : "From the first pour · \(samples.count) readings saved"
                        )
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
                Chart {
                    ForEach(chartSamples, id: \.elapsed) { sample in
                        LineMark(
                            x: .value("Time", sample.elapsed),
                            y: .value(
                                "Water",
                                recipe.totalWater > 0
                                    ? min(100, sample.water / Double(recipe.totalWater) * 100)
                                    : 0
                            ),
                            series: .value("Metric", "Water")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StudioTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        LineMark(
                            x: .value("Time", sample.elapsed),
                            y: .value(
                                "Coffee collected",
                                yieldScale > 0
                                    ? min(100, sample.coffeeWeight / yieldScale * 100)
                                    : 0
                            ),
                            series: .value("Metric", "Cup yield")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StudioTheme.mint)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 3,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: [7, 5]
                            )
                        )
                    }

                    RuleMark(y: .value("Target", 100))
                        .foregroundStyle(.white.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    ForEach(chartTimelineEvents) { event in
                        RuleMark(x: .value("Recipe event", event.elapsed))
                            .foregroundStyle(
                                event.kind == .pour
                                    ? StudioTheme.accent.opacity(0.52)
                                    : .white.opacity(0.13)
                            )
                            .lineStyle(
                                StrokeStyle(
                                    lineWidth: event.kind == .pour ? 1.4 : 1,
                                    dash: event.kind == .pour ? [] : [2, 4]
                                )
                            )
                            .annotation(position: .top, alignment: .leading) {
                                if event.kind == .pour {
                                    Text(event.title)
                                        .font(.system(size: 8, weight: .bold, design: .rounded))
                                        .foregroundStyle(StudioTheme.accent)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(StudioTheme.panel.opacity(0.92), in: Capsule())
                                }
                            }
                    }
                }
                .frame(height: 210)
                .chartXScale(domain: 0...chartDuration)
                .chartYScale(domain: 0...100)
                .overlay {
                    if chartSamples.isEmpty {
                        Text(
                            mode == .live
                                ? "Waiting for the machine to finish grinding and heating"
                                : "Waiting for the first pour"
                        )
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(StudioTheme.muted)
                        .padding(.horizontal, 24)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                            .foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel {
                            if let percent = value.as(Int.self) {
                                Text("\(percent)%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(StudioTheme.muted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(.white.opacity(0.05))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(durationText(seconds))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(StudioTheme.muted)
                            }
                        }
                    }
                }
                .chartPlotStyle { plot in
                    plot
                        .background(.black.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
                }

                HStack(spacing: 10) {
                    chartLegend(
                        "Water",
                        value: "\(Int(water.rounded())) / \(recipe.totalWater) ml",
                        color: StudioTheme.accent
                    )
                    chartLegend(
                        "Cup yield",
                        value: hasYieldSignal
                            ? "\(Int(weight.rounded())) / \(Int(expectedCupYield.rounded())) g"
                            : "no reading",
                        color: hasYieldSignal ? StudioTheme.mint : StudioTheme.muted
                    )
                }

                if pouredWithoutGrinding {
                    Label(
                        "This recipe grinds, but the machine never reported grinding — "
                            + "it went straight to pouring. Check the grinder before "
                            + "you drink this one.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if scaleIsSilent {
                    // Better to say the scale is not reporting than to draw a
                    // flat line at zero and call it a measurement.
                    Label(
                        "The machine's scale is not reporting the cup. Check that the "
                            + "cup is on the scale plate and that nothing is leaning on it.",
                        systemImage: "scalemass"
                    )
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Label("Pour start", systemImage: "line.diagonal")
                        .foregroundStyle(StudioTheme.accent)
                    Label("Rest", systemImage: "ellipsis")
                        .foregroundStyle(StudioTheme.muted)
                    Spacer()
                    Text("Target 100%")
                        .foregroundStyle(StudioTheme.muted)
                }
                .font(.caption2.weight(.semibold))

            }
        }
    }

    func chartLegend(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.muted)
                Text(value)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip, style: .continuous))
    }

    enum LivePourState {
        case done
        case active
        case upcoming
    }

    func stateIcon(for state: LivePourState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .active: "drop.circle.fill"
        case .upcoming: "circle"
        }
    }

    /// True once the machine is actually working through the pours. While it is
    /// still grinding or heating, no pour is under way — marking the first one
    /// active there put "Grinding beans · 0 / 50 ml" inside the bloom card.
    var hasStartedPouring: Bool {
        [.blooming, .pouring, .resting].contains(currentPhase)
    }

    func state(ofPour index: Int) -> LivePourState {
        if (finished && currentPhase == .complete) || index < activePourIndex { return .done }
        guard hasStartedPouring else { return .upcoming }
        return index == activePourIndex ? .active : .upcoming
    }

    /// Water already delivered into this particular pour, from the running
    /// total. Pours before it have to be complete for it to be under way.
    func delivered(inPour index: Int) -> Double {
        let before = recipe.pours.prefix(index).reduce(0.0) { $0 + Double($1.volume) }
        let capacity = Double(recipe.pours[index].volume)
        return min(capacity, max(0, water - before))
    }

    var pourTimeline: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "Pours",
                    detail: hasStartedPouring
                        ? "\(min(activePourIndex + 1, recipe.pours.count)) of \(recipe.pours.count)"
                        : "\(recipe.pours.count) steps",
                    icon: "list.number"
                )
                ForEach(Array(recipe.pours.enumerated()), id: \.element.id) { index, pour in
                    livePourCard(index: index, pour: pour)
                }
            }
        }
    }

    func livePourCard(index: Int, pour: PourStep) -> some View {
        let state = state(ofPour: index)
        let delivered = delivered(inPour: index)
        let capacity = Double(max(1, pour.volume))
        let share = recipe.totalWater > 0
            ? Int((Double(pour.volume) / Double(recipe.totalWater) * 100).rounded())
            : 0
        let tint: Color = switch state {
        case .done: StudioTheme.mint
        case .active: StudioTheme.accent
        case .upcoming: StudioTheme.muted.opacity(0.9)
        }

        return VStack(spacing: 12) {
            HStack(spacing: 13) {
                // The share of total water used to be set at 34pt in a fixed
                // 66pt column — the biggest number on the brew screen, for the
                // fact that matters least, squeezing the pattern and flow rate
                // into "Spiral p…". It is a caption now, and it says what it is.
                PourPatternMark(pattern: pour.pattern, color: tint, size: 30)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(index == 0 ? "Bloom" : "Pour \(index + 1)")
                            .font(.subheadline.weight(.bold))
                        Text("\(pour.volume) ml · \(pour.temperature)°C")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    HStack(spacing: 8) {
                        Text(patternTitle(pour.pattern))
                        Text("·")
                        Text("\(String(format: "%.1f", pour.flowRate)) ml/s")
                        if pour.pauseAfter > 0 {
                            Text("·")
                            Text("\(pour.pauseAfter)s rest")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(index == 0 ? "Bloom" : "Pour \(index + 1)"), \(pour.volume) millilitres at "
                        + "\(pour.temperature) degrees, \(share) percent of the water, "
                        + "\(patternTitle(pour.pattern))"
                )

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    Image(systemName: stateIcon(for: state))
                        .font(.title3)
                        .foregroundStyle(tint)
                    if pour.agitationBefore || pour.agitationAfter {
                        AgitationTimingMarks(
                            before: pour.agitationBefore,
                            after: pour.agitationAfter,
                            size: 17
                        )
                    }
                }
            }

            // Only the running pour gets a live bar; the others would just be
            // a full or empty rectangle saying nothing.
            if state == .active, mode == .live || !finished {
                VStack(spacing: 5) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(StudioTheme.raised)
                            Capsule()
                                .fill(tint)
                                .frame(width: proxy.size.width * min(1, delivered / capacity))
                                .animation(.smooth(duration: 0.25), value: delivered)
                        }
                    }
                    .frame(height: 8)
                    HStack {
                        Text(stageTitle(for: currentPhase))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(tint)
                        Spacer()
                        Text("\(Int(delivered.rounded())) / \(pour.volume) ml")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
            }
        }
        .padding(14)
        .background(
            state == .active ? StudioTheme.raised : StudioTheme.panel,
            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous)
                .stroke(
                    state == .active ? tint : .white.opacity(0.08),
                    lineWidth: state == .active ? 2 : 1
                )
        }
        .opacity(state == .upcoming ? 0.62 : 1)
        .animation(.snappy(duration: 0.22), value: state)
    }

}
