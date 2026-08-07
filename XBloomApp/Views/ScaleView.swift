import SwiftUI
import XBloomCore

/// The machine's built-in scale, driven from the phone.
///
/// Opening this screen puts the machine on its own scale page so its display
/// follows along, and taring here tares the machine itself.
struct ScaleView: View {
    @Environment(XBloomBLEClient.self) private var machine
    @State private var status: MachineToolStatus = .idle
    @State private var isWorking = false
    @State private var peakWeight: Double = 0
    @State private var showsGrams = true

    private var weight: Double { machine.telemetry.weight ?? 0 }

    private var displayedWeight: String {
        let value = showsGrams ? weight : weight / 28.3495
        return String(format: showsGrams ? "%.1f" : "%.2f", value)
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 22) {
                    readout
                    controls
                    MachineToolStatusCard(status: status)
                    notes
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Scale")
        .navigationBarTitleDisplayMode(.inline)
        .task { await open() }
        .onDisappear {
            Task { await machine.closeScale() }
        }
        .onChange(of: machine.telemetry.weight) { _, new in
            peakWeight = max(peakWeight, new ?? 0)
        }
    }

    private var readout: some View {
        VStack(spacing: 10) {
            Text(displayedWeight)
                .font(.system(size: 76, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.2), value: weight)
            Text(showsGrams ? "grams" : "ounces")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                MetricChip(title: "Peak", value: String(format: "%.1f g", peakWeight))
                MetricChip(
                    title: "Machine",
                    value: machine.isConnected ? "Connected" : "Offline"
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .appCard()
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await tare() }
            } label: {
                Label("Tare", systemImage: "scalemass")
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(!machine.isConnected || isWorking)

            HStack(spacing: 12) {
                Button {
                    showsGrams.toggle()
                } label: {
                    Label(showsGrams ? "Show ounces" : "Show grams", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.bordered)

                Button {
                    peakWeight = weight
                } label: {
                    Label("Reset peak", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionHeader(title: "About this screen")
            Text(
                "Weight comes from the machine's own load cell, several times a "
                    + "second. Tare clears it on the machine, not just here. "
                    + "Unit switching is display-only and does not change the "
                    + "machine's setting."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .appCard()
    }

    private func open() async {
        guard machine.isConnected else {
            status = .failed("Connect to the machine first.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await machine.openScale()
                ? .succeeded("Scale open on the machine")
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
                peakWeight = 0
                status = .succeeded("Tared")
            } else {
                status = .unacknowledged("The machine did not acknowledge the tare.")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

/// How a direct machine command turned out. The machine echoes commands it
/// understands, so "sent but never acknowledged" is a distinct and meaningful
/// outcome — not a silent success.
enum MachineToolStatus: Equatable {
    case idle
    case succeeded(String)
    case unacknowledged(String)
    case failed(String)
}

struct MachineToolStatusCard: View {
    let status: MachineToolStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .succeeded(let message):
            row(message, icon: "checkmark.circle.fill", tint: AppTheme.sage)
        case .unacknowledged(let message):
            row(
                message + " The command was sent, but this control has not been "
                    + "confirmed against a real machine capture yet.",
                icon: "questionmark.circle.fill",
                tint: .orange
            )
        case .failed(let message):
            row(message, icon: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    private func row(_ message: String, icon: String, tint: Color) -> some View {
        Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct MetricChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.white.opacity(0.06), in: Capsule())
    }
}
