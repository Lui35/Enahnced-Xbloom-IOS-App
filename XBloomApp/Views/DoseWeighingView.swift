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

    private var target: Double { recipe.dose }

    /// What will actually be used. Normally the live scale reading; a manual
    /// entry takes over if the user has corrected it.
    private var measured: Double {
        manualAdjustment ?? max(0, machine.telemetry.weight ?? 0)
    }

    private var difference: Double { measured - target }

    /// Anything inside a tenth of a gram is as close as this scale resolves.
    private var isOnTarget: Bool { abs(difference) <= 0.15 }
    private var isClose: Bool { abs(difference) <= 0.6 }

    private var tint: Color {
        if isOnTarget { return StudioTheme.mint }
        if isClose { return .orange }
        return measured > target ? .red : StudioTheme.muted
    }

    private var guidance: String {
        if !hasTared { return "Put your container on the scale, then tare" }
        if isOnTarget { return "On target" }
        if difference < 0 {
            return String(format: "Add %.1f g", -difference)
        }
        return String(format: "%.1f g over — brewing will use the real weight", difference)
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
                .foregroundStyle(isOnTarget ? StudioTheme.mint : .white)
                .multilineTextAlignment(.center)

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
                    .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!machine.isConnected || isWorking)
                .opacity(machine.isConnected ? 1 : 0.5)

                stepRow(
                    number: 2,
                    title: "Add beans until the ring turns green",
                    done: reachedTargetOnce
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
                        + "rounded target."
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
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                    Text("The machine accepts 5–30 g. Adjust the dose to continue.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                    onConfirm(confirmedDose)
                    dismiss()
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
                }
                .buttonStyle(.plain)

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
