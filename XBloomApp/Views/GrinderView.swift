import SwiftUI
import XBloomCore

/// Grind on its own, without a recipe attached.
///
/// Unlike the scale and the brewer, nothing here has been seen in a real
/// traffic capture: the grinder commands come from the vendor's command table,
/// but their payload shapes are unverified. Every control therefore reports
/// whether the machine actually acknowledged it, rather than assuming success.
struct GrinderView: View {
    @Environment(XBloomBLEClient.self) private var machine
    @State private var grindSize = 50.0
    @State private var rpm = 80.0
    @State private var status: MachineToolStatus = .idle
    @State private var isWorking = false
    @State private var isGrinding = false
    /// The command landed, but the burrs are still being walked to the setting.
    /// A capture of the machine moving from one size to another spends 5.5 s
    /// here — 24 `device_gears` steps — before it grinds anything.
    @State private var isPositioning = false
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var ticker: Task<Void, Never>?

    private var size: Int { Int(grindSize.rounded()) }
    private var band: GrindGuide { GrindSizeGuide.band(for: size) }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    readout
                    settings
                    guideCard
                    actions
                    MachineToolStatusCard(status: status)
                    notes
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Grinder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onDisappear {
            ticker?.cancel()
            ticker = nil
            // Walking away from a running grinder has to stop it first, the
            // same order the vendor's app uses: pause, end, then leave.
            let wasRunning = isGrinding || isPositioning
            Task {
                if wasRunning { _ = try? await machine.stopGrinding() }
                await machine.closeGrinder()
            }
        }
        .onChange(of: machine.telemetry.state) { _, state in
            if isPositioning, state == .grinding {
                beginGrinding()
            } else if isGrinding, state == .idle {
                finishGrinding(message: "The machine reported the grinder stopped")
            }
        }
    }

    private var readout: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.raised, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, Double(size) / 80))
                    .stroke(grindTint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.2), value: grindSize)
                // The same grey travel as the dial: how far round the burrs
                // have actually come, laid over the setting they are heading
                // for.
                if let machinePosition {
                    Circle()
                        .trim(from: 0, to: max(0.02, machinePosition / 80))
                        .stroke(StudioTheme.muted, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.28), value: machinePosition)
                }
                VStack(spacing: 2) {
                    Text(isGrinding ? "\(Int(elapsed.rounded()))" : "\(size)")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(isGrinding ? "seconds" : isPositioning ? "moving to" : "grind")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                }
            }
            .frame(width: 138, height: 138)

            Text(isPositioning ? "Setting the burrs" : band.method)
                .font(.title2.weight(.bold))
            Text(
                isPositioning
                    ? machinePosition.map { "Passing size \(Int($0)) on the way to \(size)" }
                        ?? "Stepping to size \(size) — it grinds when it arrives"
                    : band.detail
            )
            .font(.subheadline)
            .foregroundStyle(StudioTheme.muted)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private var settings: some View {
        StudioCard {
            VStack(spacing: 12) {
                StudioSectionTitle(
                    title: "Grinder",
                    detail: "Drag each bar to set it",
                    icon: "circle.grid.cross.fill"
                )
                StudioDialBox(
                    title: "Grind size",
                    value: $grindSize,
                    range: 1...80,
                    tint: grindTint,
                    caption: band.method,
                    machineValue: machinePosition
                )
                .opacity(isBusy ? 0.45 : 1)
                .allowsHitTesting(!isBusy)

                StudioDialBox(
                    title: "Grinder speed",
                    value: $rpm,
                    range: 60...120,
                    step: 10,
                    unit: "RPM",
                    tint: StudioTheme.accent
                )
                .opacity(isBusy ? 0.45 : 1)
                .allowsHitTesting(!isBusy)
            }
        }
    }

    /// The full dial laid out, so the whole range is visible rather than only
    /// the band the dial happens to be sitting in.
    private var guideCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 11) {
                StudioSectionTitle(
                    title: "Grind guide",
                    detail: "What each part of the dial suits",
                    icon: "list.bullet"
                )
                ForEach(GrindSizeGuide.bands) { guide in
                    let active = guide.range.contains(size)
                    HStack(spacing: 12) {
                        Text("\(guide.range.lowerBound)–\(guide.range.upperBound)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(active ? .black : StudioTheme.muted)
                            .frame(width: 54)
                            .padding(.vertical, 6)
                            .background(
                                active ? AnyShapeStyle(grindTint) : AnyShapeStyle(StudioTheme.raised),
                                in: Capsule()
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(guide.method)
                                .font(.subheadline.weight(active ? .bold : .semibold))
                            Text(guide.detail)
                                .font(.caption2)
                                .foregroundStyle(StudioTheme.muted)
                        }
                        Spacer()
                        if active {
                            Image(systemName: "arrow.left")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(grindTint)
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if isGrinding || isPositioning {
                Button(role: .destructive) {
                    Task { await stop() }
                } label: {
                    Label(isPositioning ? "Cancel" : "Stop grinding", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.danger)
            } else {
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isWorking ? "Sending…" : "Start grinding")
                                .font(.headline)
                            Text("\(band.method) · size \(size) · \(Int(rpm)) RPM")
                                .font(.caption)
                                .opacity(0.62)
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill")
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
            }

            HStack(spacing: 10) {
                StudioReadoutChip(
                    title: "Machine report",
                    value: machine.telemetry.grinderReport.map(String.init) ?? "—"
                )
                StudioReadoutChip(
                    title: "Gear",
                    value: machine.telemetry.gearPosition.map(String.init) ?? "—"
                )
                StudioReadoutChip(
                    title: "State",
                    value: machine.telemetry.state.rawValue.capitalized
                )
            }

            Text("Put the dripper in the grinder cradle before starting.")
                .font(.caption2)
                .foregroundStyle(StudioTheme.muted)
        }
    }

    private var notes: some View {
        StudioCard(accent: StudioTheme.warning) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Not yet verified", systemImage: "questionmark.circle.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StudioTheme.warning)
                Text(
                    "These grinder commands come from the official app's command "
                        + "table, but no recording has confirmed their payloads on "
                        + "this machine. If a control does nothing, record a session "
                        + "in Settings → Machine diagnostics — the transcript will "
                        + "show what the machine made of it."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
                Text(
                    "\"Machine report\" is the grinder's own progress value, shown "
                        + "raw. It is not grams: the units are unknown."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    /// Where the burrs actually are, on the same 1–80 dial.
    ///
    /// `device_gears` counts in dial units offset by thirty, and the machine
    /// streams one step every ~200 ms while it travels — so the grey bar moves
    /// because the machine moved, not because a timer said it should have.
    /// Nil until the machine has reported a position at all.
    private var machinePosition: Double? {
        machine.telemetry.gearPosition
            .flatMap(XBloomProtocol.grindSize(atGear:))
            .map(Double.init)
    }

    private var grindTint: Color { StudioTheme.crema }

    private func start() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let speed = Int(rpm.rounded())
            let configured = try await machine.prepareGrinder(size: size, speed: speed)
            let started = try await machine.startGrinding(size: size, speed: speed)
            guard started else {
                status = .unacknowledged("The machine did not acknowledge the grind command.")
                return
            }
            isPositioning = true
            elapsed = 0
            status = configured
                ? .succeeded("Moving the burrs to size \(size) · \(Int(rpm)) RPM")
                : .unacknowledged("Grinding started, but the size and speed were not acknowledged.")
            // A machine already at the requested setting reports `grinder_doing`
            // before this runs, and `onChange` never fires for a value that did
            // not change.
            if machine.telemetry.state == .grinding { beginGrinding() }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let stopped = try await machine.stopGrinding()
            let seconds = Int(elapsed.rounded())
            finishGrinding(
                message: isGrinding
                    ? "Stopped after \(seconds) s"
                    : "Cancelled before the burrs finished moving"
            )
            if !stopped {
                status = .unacknowledged("Stop was sent but not acknowledged — check the machine.")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// The machine has reported `grinder_doing`. Everything before this was
    /// the burr carrier travelling, and timing it as grind time is what made a
    /// two-second grind read as eight.
    private func beginGrinding() {
        isPositioning = false
        isGrinding = true
        startedAt = Date()
        elapsed = 0
        startTicker()
        status = .succeeded("Grinding · \(band.method) · size \(size), \(Int(rpm)) RPM")
    }

    private func finishGrinding(message: String) {
        ticker?.cancel()
        ticker = nil
        isGrinding = false
        isPositioning = false
        status = .succeeded(message)
    }

    /// The machine is busy either way — moving the burrs or grinding — and the
    /// dials must not send a new setting into the middle of it.
    private var isBusy: Bool { isGrinding || isPositioning }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let startedAt else { return }
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }
}

struct StudioReadoutChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(StudioTheme.muted)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.chip, style: .continuous))
    }
}
