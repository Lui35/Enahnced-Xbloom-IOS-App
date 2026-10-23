import SwiftUI

/// Shared by every machine toolbar; opening status never disconnects the machine.
struct MachineConnectionButton: View {
    @Environment(XBloomBLEClient.self) private var machine
    @State private var showsMachine = false

    private var isConnecting: Bool {
        [.scanning, .connecting, .subscribing].contains(machine.connectionState)
    }

    var body: some View {
        Button { showsMachine = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if isConnecting {
                        ProgressView().tint(StudioTheme.accent)
                    } else {
                        Image(systemName: machine.isConnected
                              ? "antenna.radiowaves.left.and.right"
                              : "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(machine.isConnected ? StudioTheme.mint : StudioTheme.accent)
                    }
                }
                .frame(width: 44, height: 44)
                if machine.isConnected {
                    Circle()
                        .fill(StudioTheme.mint)
                        .frame(width: 7, height: 7)
                        .overlay { Circle().stroke(StudioTheme.background, lineWidth: 2) }
                        .offset(x: -4, y: -5)
                }
            }
        }
        .accessibilityLabel("Machine connection")
        .accessibilityValue(machine.isConnected ? "Connected" : isConnecting ? "Connecting" : "Not connected")
        .accessibilityHint("Opens machine controls and connection status")
        .accessibilityIdentifier("machine.connection")
        .sheet(isPresented: $showsMachine) { MachineConnectionPanel() }
    }

}

struct MachineConnectionPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(XBloomBLEClient.self) private var machine

    var body: some View {
        NavigationStack {
            ScrollView {
                machineHero.padding(StudioTheme.Space.margin)
            }
            .background(StudioTheme.background)
            .navigationTitle("Your machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.frame(minHeight: 44)
                }
            }
        }
        .tint(StudioTheme.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isConnecting: Bool {
        [.scanning, .connecting, .subscribing].contains(machine.connectionState)
    }

    private var adaptiveHeaderLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    }

    private var machineHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            adaptiveHeaderLayout {
                IconBadge(systemImage: "antenna.radiowaves.left.and.right", tint: machine.isConnected ? StudioTheme.mint : StudioTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(machine.machineName).font(.headline)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(machine.isConnected ? StudioTheme.mint : StudioTheme.muted)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(machine.isConnected ? "Connected · Live controls ready" : isConnecting ? "Looking for your machine…" : "Not connected")
                            .font(.caption)
                            .foregroundStyle(machine.isConnected ? StudioTheme.mint : StudioTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                if machine.isConnected {
                    Menu {
                        Button("Test connection (moves tray)", systemImage: "wave.3.right") {
                            Task { await machine.testConnection() }
                        }.disabled(machine.diagnosticState == .testing)
                        Button("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash") { machine.disconnect() }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }.accessibilityLabel("Machine actions")
                } else {
                    Button { machine.connect() } label: {
                        Group {
                            if isConnecting { ProgressView().tint(StudioTheme.accent) }
                            else { Text("Connect").font(.subheadline.weight(.semibold)) }
                        }
                        .frame(minWidth: 68, minHeight: 44)
                        .padding(.horizontal, 6)
                        .background(StudioTheme.accent.opacity(0.12), in: Capsule())
                    }
                    .disabled(isConnecting)
                    .accessibilityLabel(isConnecting ? "Connecting to machine" : "Connect machine")
                    .accessibilityIdentifier("machine.connect")
                }
            }
            if machine.isConnected {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3), spacing: 8) {
                    heroMetric("Weight", machine.telemetry.weight, "g")
                    heroMetric("Water", machine.telemetry.waterVolume, "ml")
                    heroMetric("Temp", machine.telemetry.temperature, "°")
                }
                Text(machine.telemetry.state.rawValue.capitalized)
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            } else {
                Text("Keep your machine awake and your phone nearby.")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
            diagnosticMessage
            if let error = machine.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(StudioTheme.danger)
            }
        }
        .studioCard(padding: 18)
    }

    private func heroMetric(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioTheme.muted)
            Text(value.map { "\(String(format: "%.1f", $0))\(unit)" } ?? "—")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
    }

    @ViewBuilder
    private var diagnosticMessage: some View {
        switch machine.diagnosticState {
        case .idle: EmptyView()
        case .testing:
            Label("Sending a safe movement test…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.crema)
        case .passed:
            Label("Machine responded — command channel verified.", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.mint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(StudioTheme.danger)
        }
    }

}
