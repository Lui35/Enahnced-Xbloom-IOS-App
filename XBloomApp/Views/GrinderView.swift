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
    @State private var grindSize = 50
    @State private var rpm: GrinderRPM = .rpm80
    @State private var status: MachineToolStatus = .idle
    @State private var isWorking = false
    @State private var isGrinding = false
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var ticker: Task<Void, Never>?

    /// The dripper sits away from the scale while grinding, so the load cell is
    /// not a dose readout. The machine's own grinder report is shown instead,
    /// unlabelled, because its units are not established.
    private var grinderReport: UInt32? { machine.telemetry.grinderReport }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 20) {
                    readout
                    sizeCard
                    speedCard
                    actions
                    MachineToolStatusCard(status: status)
                    notes
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Grinder")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            ticker?.cancel()
            ticker = nil
            Task { await machine.closeGrinder() }
        }
        .onChange(of: machine.telemetry.state) { _, state in
            if isGrinding, state == .idle {
                finishGrinding(message: "The machine reported the grinder stopped")
            }
        }
    }

    private var readout: some View {
        VStack(spacing: 10) {
            Text(isGrinding ? String(format: "%.0f", elapsed) : "\(grindSize)")
                .font(.system(size: 68, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.2), value: isGrinding ? elapsed : Double(grindSize))
            Text(isGrinding ? "seconds grinding" : "grind size")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                MetricChip(title: "Speed", value: "\(rpm.rawValue) rpm")
                MetricChip(
                    title: "Machine report",
                    value: grinderReport.map(String.init) ?? "—"
                )
                MetricChip(
                    title: "Gear",
                    value: machine.telemetry.gearPosition.map(String.init) ?? "—"
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .appCard()
    }

    private var sizeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Grind size", systemImage: "circle.grid.cross.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.crema)
                Spacer()
                Text("\(grindSize)")
                    .font(.headline.monospacedDigit())
            }
            Slider(
                value: Binding(
                    get: { Double(grindSize) },
                    set: { grindSize = Int($0.rounded()) }
                ),
                in: 1...80,
                step: 1
            )
            .tint(AppTheme.crema)
            .disabled(isGrinding)
            HStack {
                Text("1 · finest").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("80 · coarsest").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .appCard()
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader(title: "Grind speed")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(GrinderRPM.allCases.filter { $0 != .off }, id: \.self) { option in
                    Button {
                        rpm = option
                    } label: {
                        Text("\(option.rawValue)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(rpm == option ? AppTheme.espresso : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                rpm == option ? AnyShapeStyle(AppTheme.crema) : AnyShapeStyle(.white.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isGrinding)
                }
            }
        }
        .appCard()
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if isGrinding {
                Button(role: .destructive) {
                    Task { await stop() }
                } label: {
                    Label("Stop grinding", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task { await start() }
                } label: {
                    Label(isWorking ? "Sending…" : "Start grinding", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!machine.isConnected || isWorking)
            }

            Text("Put the dripper in the grinder cradle before starting.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionHeader(title: "Not yet verified")
            Text(
                "These grinder commands come from the official app's command "
                    + "table, but no recording has confirmed their payloads on "
                    + "this machine. If a control does nothing, record a session "
                    + "in Settings → Machine diagnostics — the transcript will "
                    + "show what the machine made of it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "\"Machine report\" is the grinder's own progress value, shown "
                    + "raw. It is not grams: the units are unknown."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .appCard()
    }

    private func start() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let configured = try await machine.prepareGrinder(size: grindSize, speed: rpm.rawValue)
            let started = try await machine.startGrinding()
            guard started else {
                status = .unacknowledged("The machine did not acknowledge the grind command.")
                return
            }
            isGrinding = true
            startedAt = Date()
            elapsed = 0
            startTicker()
            status = configured
                ? .succeeded("Grinding at size \(grindSize), \(rpm.rawValue) rpm")
                : .unacknowledged("Grinding started, but the size and speed were not acknowledged.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let stopped = try await machine.stopGrinding()
            finishGrinding(
                message: stopped
                    ? "Stopped after \(Int(elapsed.rounded())) s"
                    : "Stop was sent but not acknowledged — check the machine."
            )
            if !stopped { status = .unacknowledged("Stop was sent but not acknowledged.") }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func finishGrinding(message: String) {
        ticker?.cancel()
        ticker = nil
        isGrinding = false
        if case .unacknowledged = status {} else {
            status = .succeeded(message)
        }
    }

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
