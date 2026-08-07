import SwiftUI
import XBloomCore

/// One pour, set up by hand and run straight from the phone.
///
/// The pour is sent as a single-step, grinder-off recipe. That is the same
/// encoding path a normal brew takes, and the only one verified against a
/// recording of this machine — so the volume, temperature, flow rate, and
/// pattern chosen here are known to arrive as intended.
struct ManualPourView: View {
    @Environment(XBloomBLEClient.self) private var machine
    @State private var volume = 60.0
    @State private var temperature = 93.0
    @State private var flowRate = 3.2
    @State private var pattern: PourPattern = .spiral
    @State private var agitation = false
    @State private var status: MachineToolStatus = .idle
    @State private var isStarting = false
    @State private var isRunning = false

    private var pour: ManualPour {
        ManualPour(
            volume: Int(volume.rounded()),
            temperature: Int(temperature.rounded()),
            flowRate: flowRate,
            pattern: pattern,
            agitation: agitation
        )
    }

    private var poured: Double { machine.telemetry.waterVolume ?? 0 }
    private var fraction: Double { min(1, poured / max(1, volume)) }
    private var issues: [ValidationIssue] { pour.validate() }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    readout
                    parameters
                    patternCard
                    actions
                    MachineToolStatusCard(status: status)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Brewer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onChange(of: machine.brewProgress) {
            guard isRunning, machine.brewProgress.completedAt != nil else { return }
            isRunning = false
            status = .succeeded("Pour finished")
        }
    }

    private var readout: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(StudioTheme.raised, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(StudioTheme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.25), value: fraction)
                VStack(spacing: 2) {
                    Text("\(Int(poured.rounded()))")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(Int(volume)) ml")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                }
            }
            .frame(width: 138, height: 138)

            Text(isRunning ? "Pouring" : "Ready")
                .font(.title2.weight(.bold))
            Text(machine.isConnected ? machine.machineName : "Not connected")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)

            HStack(spacing: 10) {
                StudioReadoutChip(
                    title: "Temp",
                    value: machine.telemetry.temperature.map { String(format: "%.0f°C", $0) } ?? "—"
                )
                StudioReadoutChip(
                    title: "Cup",
                    value: String(format: "%.1f g", machine.telemetry.weight ?? 0)
                )
                StudioReadoutChip(
                    title: "Est.",
                    value: String(format: "%.0f s", pour.estimatedDuration)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private var parameters: some View {
        StudioCard {
            VStack(spacing: 12) {
                StudioSectionTitle(
                    title: "This pour",
                    detail: "Drag each bar",
                    icon: "slider.horizontal.3"
                )
                StudioDialBox(
                    title: "Volume",
                    value: $volume,
                    range: Double(ManualPour.volumeRange.lowerBound)...Double(ManualPour.volumeRange.upperBound),
                    step: 5,
                    unit: "ml"
                )
                StudioDialBox(
                    title: "Temperature",
                    value: $temperature,
                    range: Double(ManualPour.temperatureRange.lowerBound)...Double(ManualPour.temperatureRange.upperBound),
                    unit: "°C",
                    tint: .orange
                )
                StudioDialBox(
                    title: "Flow rate",
                    value: $flowRate,
                    range: ManualPour.flowRateRange.lowerBound...ManualPour.flowRateRange.upperBound,
                    step: 0.1,
                    unit: "ml/s",
                    decimals: 1,
                    tint: .blue
                )
            }
            .opacity(isRunning ? 0.45 : 1)
            .allowsHitTesting(!isRunning)
        }
    }

    private var patternCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionTitle(title: "Pattern", icon: "scribble.variable")
                PourPatternSelector(selection: $pattern)
                    .frame(height: 96)
                Toggle(isOn: $agitation) {
                    Label("Agitate before pouring", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(StudioTheme.mint)
            }
            .opacity(isRunning ? 0.45 : 1)
            .allowsHitTesting(!isRunning)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let issue = issues.first {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isRunning {
                Button(role: .destructive) {
                    stop()
                } label: {
                    Label("Stop pour", systemImage: "stop.fill")
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
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isStarting ? "Sending…" : "Start pour")
                                .font(.headline)
                            Text("\(Int(volume)) ml · \(Int(temperature))°C · \(String(format: "%.1f", flowRate)) ml/s")
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
                    .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!machine.isConnected || isStarting || !issues.isEmpty)
                .opacity(machine.isConnected && issues.isEmpty ? 1 : 0.5)
            }

            Text(
                "Hot water is dispensed as soon as the machine accepts this. "
                    + "Make sure the dripper and cup are in place."
            )
            .font(.caption2)
            .foregroundStyle(StudioTheme.muted)
            .multilineTextAlignment(.center)
        }
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        do {
            try await machine.startManualPour(pour)
            isRunning = true
            status = .succeeded("Pouring")
        } catch XBloomBLEClient.MachineError.noMachineResponse {
            // The execute command may still have landed. Keep watching rather
            // than claiming a failure while water is coming out.
            isRunning = true
            status = .unacknowledged("Sent, but the machine has not reported back yet.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        do {
            try machine.stopBrew()
            isRunning = false
            status = .succeeded("Stopped")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
