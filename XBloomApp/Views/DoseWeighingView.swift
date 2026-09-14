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
    @State private var weighing = DoseWeighingState()
    @State private var reachedTargetOnce = false
    private var confirmedDose: Double { weighing.confirmedDose ?? 0 }
    private var target: Double { recipe.dose }
    private var measured: Double { weighing.measured }

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
        if !hasTared && measured < DoseFit.emptyPanThreshold {
            return "Tare on the phone or machine, then add beans"
        }
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
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stage == .loading {
                        Button("Back") {
                            withAnimation(.snappy) {
                                weighing.reweigh()
                                stage = .weighing
                            }
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
            .task { await openScale() }
            .onDisappear { Task { await machine.closeScale() } }
            .onChange(of: machine.telemetry.weight, initial: true) { _, weight in
                if let weight { weighing.ingest(weight: weight) }
            }
            .onChange(of: machine.scaleTareRevision) { _, _ in
                resetTare()
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
                    detail: weighing.adjustment == nil ? "From the scale" : "Set by hand",
                    icon: "scalemass.fill"
                )
                StudioDialBox(
                    title: "Adjust if needed",
                    value: Binding(
                        get: { measured },
                        set: { weighing.adjustment = $0 }
                    ),
                    range: 1...40,
                    step: 0.1,
                    unit: "g",
                    decimals: 1,
                    tint: tint,
                    height: 84
                )
                if weighing.adjustment != nil {
                    Button("Follow the scale again") {
                        weighing.adjustment = nil
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
    private var isDoseBrewable: Bool { weighing.isBrewable }

    private var loadingStage: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(StudioTheme.mint)
                Text(String(format: "%.1f g dose confirmed", confirmedDose))
                    .font(.title2.weight(.bold))
                Text("Tip the beans into the grinder, then replace the weighing container with your coffee server.")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.muted)
                    .multilineTextAlignment(.center)
                Text("Your dose is saved. Moving containers on the scale will not change it.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            StudioCard {
                VStack(alignment: .leading, spacing: 8) {
                    StudioSectionTitle(title: "Before you start", icon: "checklist")
                    checklistRow("Beans are in the grinder, not still in your cup")
                    checklistRow("The dripper is seated on the machine")
                    checklistRow("The coffee server is on the scale beneath the dripper")
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
                    guard weighing.confirm() else { return }
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
                .disabled(!isDoseBrewable || isWorking || !machine.isConnected)
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
                        "Server in place — start brewing",
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
                .disabled(isWorking || !machine.isConnected)

                Text("This starts grinding, followed by pouring. Have the server in place first.")
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

    private func resetTare() {
        weighing.tare()
        // SwiftUI may deliver the tare event and a newer reading in one render pass.
        if let weight = machine.telemetry.weight { weighing.ingest(weight: weight) }
        guard stage == .weighing else { return }
        hasTared = true
        reachedTargetOnce = false
    }

    private func tare() async {
        isWorking = true
        defer { isWorking = false }
        do {
            if try await machine.tareScale() {
                resetTare()
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
