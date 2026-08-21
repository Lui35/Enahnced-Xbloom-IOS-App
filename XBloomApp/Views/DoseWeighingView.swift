import SwiftUI
import XBloomCore

/// Weigh the beans on the machine's own scale before a brew starts.
///
/// The recipe's dose is a target, not a measurement. Coffee does not come out
/// of the bag in exact grams, so the amount that actually goes in is nearly
/// always a little off — and that real figure is what the machine should be
/// told and what the bag should be debited by.
///
/// Only offered for recipes that grind. With the grinder off the coffee is
/// already ground and measured, and the beans never reach the scale.
struct DoseWeighingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XBloomBLEClient.self) private var machine

    let recipe: Recipe
    /// Called with the dose that was actually weighed out.
    let onConfirm: (Double) -> Void

    /// Weighing and loading are separate steps because the beans have to
    /// physically leave the scale and go into the machine in between. Going
    /// straight from a confirmed weight to a running brew started the machine
    /// with an empty grinder.
    private enum Stage {
        case weighing
        case loading
    }

    @State private var stage: Stage = .weighing
    @State private var status: MachineToolStatus = .idle
    @State private var isWorking = false
    @State private var hasTared = false
    @State private var manualAdjustment: Double?
    @State private var reachedTargetOnce = false
    /// The weight captured when the dose was confirmed. The live scale drops
    /// back to zero the moment the beans are lifted off it, so the figure that
    /// goes to the machine has to be held separately.
    @State private var confirmedDose: Double = 0

    /// An empty pan means the beans are off the scale, not that the dose is
    /// zero. Lifting the container to look at it — or tipping it early — used
    /// to drop the reading to 0.0 g, which put the dose under the machine's
    /// 5 g floor and killed the Continue button with the coffee already
    /// weighed. The last real reading since the tare is held instead.
    @State private var heldWeight: Double = 0

    private var target: Double { recipe.dose }

    private var liveWeight: Double { max(0, machine.telemetry.weight ?? 0) }

    /// What will actually be used. Normally the live scale reading; a manual
    /// entry takes over if the user has corrected it.
    private var measured: Double {
        if let manualAdjustment { return manualAdjustment }
        return liveWeight >= DoseFit.emptyPanThreshold ? liveWeight : heldWeight
    }

    /// The scale is empty but a dose was weighed on it, so the figure on
    /// screen is remembered rather than live.
    private var isHoldingReading: Bool {
        manualAdjustment == nil
            && liveWeight < DoseFit.emptyPanThreshold
            && heldWeight >= DoseFit.emptyPanThreshold
    }

    private var difference: Double { measured - target }

    /// How the weighed dose sits against the recipe's target. The bands and
    /// their margins live in `XBloomCore`; the colour and wording are this
    /// screen's business.
    private var band: DoseFit { DoseFit(measured: measured, recipe: recipe) }

    /// What the brew will actually run at with the coffee that is really in
    /// the container.
    private var projectedRatio: Double { recipe.ratio(atDose: measured) }

    private var isOnTarget: Bool { band == .onTarget }

    private var tint: Color {
        switch band {
        case .empty, .short: StudioTheme.muted
        case .close: StudioTheme.warning
        case .onTarget: StudioTheme.mint
        case .thin, .over: StudioTheme.danger
        }
    }

    private var guidance: String {
        if !hasTared { return "Put your container on the scale, then tare" }
        switch band {
        case .empty:
            return "Add your beans"
        case .onTarget:
            return "On target"
        case .close:
            let direction = difference < 0 ? "under" : "over"
            return String(
                format: "%.1f g \(direction) — fine, the brew will use %.1f g",
                abs(difference),
                measured
            )
        case .short:
            return String(format: "%.1f g under — a little weaker, still good", -difference)
        case .thin:
            return String(format: "%.1f g under — much weaker than the recipe", -difference)
        case .over:
            return String(format: "%.1f g over — stronger than the recipe", difference)
        }
    }

    private var guidanceColor: Color {
        switch band {
        case .empty, .short: .white
        case .close: StudioTheme.warning
        case .onTarget: StudioTheme.mint
        case .thin, .over: StudioTheme.danger
        }
    }

    /// Shown whenever the dose is not the recipe's, because the number that
    /// changes is not the dose the user is looking at — it is the strength of
    /// what comes out.
    private var ratioNote: String? {
        guard band != .empty, band != .onTarget, recipe.totalWater > 0, projectedRatio > 0 else {
            return nil
        }
        return String(
            format: "Brews at 1:%.1f instead of the recipe's 1:%.1f",
            projectedRatio,
            recipe.ratio
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        switch stage {
                        case .weighing:
                            readout
                            steps
                            adjustment
                            MachineToolStatusCard(status: status)
                        case .loading:
                            loadingStage
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 34)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(stage == .weighing ? "Weigh your dose" : "Load the machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stage == .loading {
                        Button("Back") {
                            withAnimation(.snappy) { stage = .weighing }
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
            .task { await openScale() }
            .onDisappear { Task { await machine.closeScale() } }
            .onChange(of: machine.telemetry.weight) { _, _ in
                guard stage == .weighing, liveWeight >= DoseFit.emptyPanThreshold else { return }
                heldWeight = liveWeight
            }
            .onChange(of: isOnTarget) { _, onTarget in
                guard stage == .weighing, onTarget, hasTared, !reachedTargetOnce else { return }
                reachedTargetOnce = true
                MachineFeedback.acknowledged()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var readout: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.raised, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: max(0.01, min(1, target > 0 ? measured / target : 0)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.2), value: measured)
                VStack(spacing: 1) {
                    Text(String(format: "%.1f", measured))
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(String(format: "%.1f", target)) g")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                }
            }
            .frame(width: 168, height: 168)
            .animation(.smooth(duration: 0.25), value: tint)

            Text(guidance)
                .font(.title3.weight(.bold))
                .foregroundStyle(guidanceColor)
                .multilineTextAlignment(.center)

            if isHoldingReading {
                Label("Holding the last reading — the scale is empty", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
            }

            if let ratioNote {
                Text(ratioNote)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.muted)
                    .multilineTextAlignment(.center)
            }

            if let name = recipe.roaster.isEmpty ? nil : recipe.roaster {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var steps: some View {
        StudioCard {
            VStack(spacing: 12) {
                StudioSectionTitle(title: "Steps", icon: "list.number")

                stepRow(
                    number: 1,
                    title: "Put your container on the scale",
                    done: hasTared
                )
                Button {
                    Task { await tare() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hasTared ? "Tare again" : "Tare")
                                .font(.headline)
                            Text("Zeroes the container's own weight")
                                .font(.caption)
                                .opacity(0.62)
                        }
                        Spacer()
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.title2)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.tile, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!machine.isConnected || isWorking)
                .opacity(machine.isConnected ? 1 : 0.5)

                stepRow(
                    number: 2,
                    title: "Add beans — a gram either way is fine",
                    done: hasTared && isDoseBrewable
                )
                stepRow(
                    number: 3,
                    title: "Tip them into the grinder, then start",
                    done: false
                )
            }
        }
    }

    private func stepRow(number: Int, title: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.heavy).monospacedDigit())
                .foregroundStyle(done ? .black : StudioTheme.muted)
                .frame(width: 26, height: 26)
                .background(
                    done ? AnyShapeStyle(StudioTheme.mint) : AnyShapeStyle(StudioTheme.raised),
                    in: Circle()
                )
            Text(title)
                .font(.subheadline)
                .foregroundStyle(done ? StudioTheme.muted : .white)
            Spacer()
            if done {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioTheme.mint)
            }
        }
    }

    /// Coffee cannot be removed a tenth of a gram at a time, so the number that
    /// goes forward is whatever is really in the container — corrected by hand
    /// if the scale and the container disagree.
    private var adjustment: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "Dose used",
                    detail: manualAdjustment == nil ? "From the scale" : "Set by hand",
                    icon: "scalemass.fill"
                )
                StudioDialBox(
                    title: "Adjust if needed",
                    value: Binding(
                        get: { measured },
                        set: { manualAdjustment = $0 }
                    ),
                    range: 1...40,
                    step: 0.1,
                    unit: "g",
                    decimals: 1,
                    tint: tint,
                    height: 84
                )
                if manualAdjustment != nil {
                    Button("Follow the scale again") {
                        manualAdjustment = nil
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.accent)
                }
                Text(
                    "This exact figure is sent to the machine, saved with the "
                        + "brew, and taken off your bean bag — not the recipe's "
                        + "rounded target. Brew short if that is all the bag "
                        + "has; the ring only says how the cup will change."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    /// The machine refuses a dose outside this range, so the brew is blocked
    /// here with an explanation rather than failing after the sheet closes.
    private var isDoseBrewable: Bool { (5.0...30.0).contains(measured) }

    /// The scale falling back to near zero is the machine's own confirmation
    /// that the beans have been lifted off it.
    private var beansLifted: Bool {
        guard let weight = machine.telemetry.weight else { return false }
        return weight < max(1, confirmedDose * 0.25)
    }

    private var loadingStage: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(StudioTheme.raised, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: beansLifted ? 1 : 0.001)
                        .stroke(StudioTheme.mint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth(duration: 0.4), value: beansLifted)
                    VStack(spacing: 1) {
                        Text(String(format: "%.1f", confirmedDose))
                            .font(.system(size: 46, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("g measured")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
                .frame(width: 168, height: 168)

                Text("Now put the beans in")
                    .font(.title2.weight(.bold))
                Text("Tip the coffee you just weighed into the grinder.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            StudioCard(accent: beansLifted ? StudioTheme.mint : StudioTheme.accent) {
                HStack(spacing: 14) {
                    Image(systemName: beansLifted ? "checkmark.circle.fill" : "arrow.up.circle")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(beansLifted ? StudioTheme.mint : StudioTheme.accent)
                        .frame(width: 50, height: 50)
                        .background(
                            (beansLifted ? StudioTheme.mint : StudioTheme.accent).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(beansLifted ? "Beans are off the scale" : "Waiting for the scale to clear")
                            .font(.headline)
                        Text(
                            beansLifted
                                ? "The machine reads \(String(format: "%.1f", machine.telemetry.weight ?? 0)) g now"
                                : "Lift the container so the reading drops back to zero"
                        )
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                }
            }

            StudioCard {
                VStack(alignment: .leading, spacing: 8) {
                    StudioSectionTitle(title: "Before you start", icon: "checklist")
                    checklistRow("Beans are in the grinder, not still in your cup")
                    checklistRow("The dripper is seated on the machine")
                    checklistRow("There is water in the tank")
                    Text(
                        "The machine will grind \(String(format: "%.1f", confirmedDose)) g at "
                            + "size \(recipe.grindSize) · \(GrindSizeGuide.method(for: recipe.grindSize)), "
                            + "then brew."
                    )
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func checklistRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(StudioTheme.accent)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }

    @ViewBuilder
    private var confirmBar: some View {
        switch stage {
        case .weighing:
            VStack(spacing: 8) {
                if measured > 0, !isDoseBrewable {
                    Text("The machine only grinds 5–30 g. Set a dose in that range to continue.")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.warning)
                }
                Button {
                    confirmedDose = measured
                    withAnimation(.snappy) { stage = .loading }
                } label: {
                    Label(
                        String(format: "Continue with %.1f g", measured),
                        systemImage: "arrow.right"
                    )
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        isDoseBrewable ? AnyShapeStyle(StudioTheme.accent) : AnyShapeStyle(StudioTheme.raised),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isDoseBrewable)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .padding(.top, 10)
            .background(.ultraThinMaterial)

        case .loading:
            VStack(spacing: 8) {
                Button {
                    Task { await handOffToBrew() }
                } label: {
                    Label(
                        String(format: "Beans are in — brew %.1f g", confirmedDose),
                        systemImage: "play.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(StudioTheme.accent, in: Capsule())
                    .opacity(isWorking ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Text("Nothing is sent to the machine until you tap this.")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.muted)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .padding(.top, 10)
            .background(.ultraThinMaterial)
        }
    }

    /// Gives the scale screen back before the recipe is handed over.
    ///
    /// Left to `onDisappear`, the exit is sent while the brew is already
    /// writing its setup commands, and the machine — still on the scale when
    /// the recipe arrives — poured without grinding. Closing it here, awaited,
    /// puts the machine back on its own home screen first; `closeScale` is a
    /// no-op afterwards, so the disappear path adds nothing.
    private func handOffToBrew() async {
        isWorking = true
        await machine.closeScale()
        isWorking = false
        onConfirm(confirmedDose)
        dismiss()
    }

    private func openScale() async {
        guard machine.isConnected else {
            status = .failed("Connect to the machine to use its scale.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await machine.openScale()
                ? .idle
                : .unacknowledged("The machine did not acknowledge the scale screen.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func tare() async {
        isWorking = true
        defer { isWorking = false }
        do {
            if try await machine.tareScale() {
                hasTared = true
                reachedTargetOnce = false
                manualAdjustment = nil
                heldWeight = 0
                MachineFeedback.acknowledged()
                status = .succeeded("Tared — now add your beans")
            } else {
                status = .unacknowledged("The machine did not acknowledge the tare.")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
