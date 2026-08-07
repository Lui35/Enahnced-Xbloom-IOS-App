import SwiftUI
import XBloomCore

/// Weigh the beans on the machine's own scale before a brew starts.
///
/// The recipe's dose is a target, not a measurement. Coffee does not come out
/// of the bag in exact grams, so the amount that actually goes in is nearly
/// always a little off — and that real figure is what the machine should be
/// told and what the bag should be debited by.
struct DoseWeighingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XBloomBLEClient.self) private var machine

    let recipe: Recipe
    /// Called with the dose that was actually weighed out.
    let onConfirm: (Double) -> Void

    @State private var status: MachineToolStatus = .idle
    @State private var isWorking = false
    @State private var hasTared = false
    @State private var manualAdjustment: Double?
    @State private var reachedTargetOnce = false

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
                        readout
                        steps
                        adjustment
                        MachineToolStatusCard(status: status)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 34)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Weigh your dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StudioTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
            .task { await openScale() }
            .onDisappear { Task { await machine.closeScale() } }
            .onChange(of: isOnTarget) { _, onTarget in
                guard onTarget, hasTared, !reachedTargetOnce else { return }
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
                    title: "Start brewing with the weight you actually got",
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

    private var confirmBar: some View {
        VStack(spacing: 8) {
            if measured > 0, !isDoseBrewable {
                Text("The machine accepts 5–30 g. Adjust the dose to continue.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                onConfirm(measured)
                dismiss()
            } label: {
                Label(
                    String(format: "Brew with %.1f g", measured),
                    systemImage: "play.fill"
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
