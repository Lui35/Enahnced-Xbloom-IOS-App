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
    @State private var pour = ManualPour()
    @State private var status: MachineToolStatus = .idle
    @State private var isStarting = false
    @State private var isRunning = false
    @State private var startedAt: Date?

    private var poured: Double { machine.telemetry.waterVolume ?? 0 }

    private var issues: [ValidationIssue] { pour.validate() }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 20) {
                    liveReadout
                    volumeCard
                    temperatureCard
                    flowCard
                    patternCard
                    actions
                    MachineToolStatusCard(status: status)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Brewer")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: machine.brewProgress) {
            guard isRunning else { return }
            if machine.brewProgress.completedAt != nil {
                isRunning = false
                status = .succeeded("Pour finished")
            }
        }
    }

    private var liveReadout: some View {
        VStack(spacing: 12) {
            Text(String(format: "%.0f", poured))
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.2), value: poured)
            Text("ml poured · target \(pour.volume) ml")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: min(1, poured / Double(max(1, pour.volume))))
                .tint(AppTheme.crema)

            HStack(spacing: 10) {
                MetricChip(
                    title: "Temp",
                    value: machine.telemetry.temperature.map { String(format: "%.0f°C", $0) } ?? "—"
                )
                MetricChip(
                    title: "Cup",
                    value: String(format: "%.1f g", machine.telemetry.weight ?? 0)
                )
                MetricChip(
                    title: "Est.",
                    value: String(format: "%.0f s", pour.estimatedDuration)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .appCard()
    }

    private var volumeCard: some View {
        settingCard(title: "Volume", value: "\(pour.volume) ml", icon: "drop.fill", tint: AppTheme.coffee) {
            Slider(
                value: Binding(
                    get: { Double(pour.volume) },
                    set: { pour.volume = Int($0.rounded()) }
                ),
                in: Double(ManualPour.volumeRange.lowerBound)...Double(ManualPour.volumeRange.upperBound),
                step: 5
            )
            .tint(AppTheme.coffee)
            .disabled(isRunning)
        }
    }

    private var temperatureCard: some View {
        settingCard(title: "Temperature", value: "\(pour.temperature) °C", icon: "thermometer.medium", tint: .orange) {
            Slider(
                value: Binding(
                    get: { Double(pour.temperature) },
                    set: { pour.temperature = Int($0.rounded()) }
                ),
                in: Double(ManualPour.temperatureRange.lowerBound)...Double(ManualPour.temperatureRange.upperBound),
                step: 1
            )
            .tint(.orange)
            .disabled(isRunning)
        }
    }

    private var flowCard: some View {
        settingCard(
            title: "Flow rate",
            value: String(format: "%.1f ml/s", pour.flowRate),
            icon: "water.waves",
            tint: AppTheme.crema
        ) {
            Slider(
                value: $pour.flowRate,
                in: ManualPour.flowRateRange.lowerBound...ManualPour.flowRateRange.upperBound,
                step: 0.1
            )
            .tint(AppTheme.crema)
            .disabled(isRunning)
        }
    }

    private var patternCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader(title: "Pattern")
            HStack(spacing: 10) {
                ForEach(PourPattern.allCases, id: \.self) { option in
                    Button {
                        pour.pattern = option
                    } label: {
                        VStack(spacing: 8) {
                            PourPatternMark(
                                pattern: option,
                                color: pour.pattern == option ? AppTheme.espresso : AppTheme.crema,
                                size: 40
                            )
                            Text(patternTitle(option))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(pour.pattern == option ? AppTheme.espresso : .primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            pour.pattern == option ? AnyShapeStyle(AppTheme.crema) : AnyShapeStyle(.white.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
            }

            Toggle(isOn: $pour.agitation) {
                Label("Agitate before pouring", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(AppTheme.sage)
            .disabled(isRunning)
        }
        .appCard()
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
                    Label(isStarting ? "Sending…" : "Start pour", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!machine.isConnected || isStarting || !issues.isEmpty)
            }

            Text(
                "Hot water is dispensed as soon as the machine accepts this. "
                    + "Make sure the dripper and cup are in place."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private func settingCard<Content: View>(
        title: String,
        value: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                Text(value)
                    .font(.headline.monospacedDigit())
            }
            content()
        }
        .appCard()
    }

    private func patternTitle(_ pattern: PourPattern) -> String {
        switch pattern {
        case .center: "Center"
        case .circular: "Circular"
        case .spiral: "Spiral"
        }
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        do {
            try await machine.startManualPour(pour)
            isRunning = true
            startedAt = Date()
            status = .succeeded("Pouring")
        } catch XBloomBLEClient.MachineError.noMachineResponse {
            // The execute command may still have landed. Keep watching rather
            // than claiming a failure while water is coming out.
            isRunning = true
            startedAt = Date()
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
