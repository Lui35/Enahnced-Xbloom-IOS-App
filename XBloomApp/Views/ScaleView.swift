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
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    readout
                    controls
                    MachineToolStatusCard(status: status)
                    notes
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Scale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { await open() }
        .onDisappear {
            Task { await machine.closeScale() }
        }
        .onChange(of: machine.telemetry.weight) { _, new in
            peakWeight = max(peakWeight, new ?? 0)
        }
    }

    private var readout: some View {
        VStack(spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(displayedWeight)
                    .font(.system(size: 78, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.2), value: weight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(showsGrams ? "g" : "oz")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(StudioTheme.muted)
            }

            Text(machine.isConnected ? machine.machineName : "Not connected")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)

            HStack(spacing: 10) {
                StudioReadoutChip(title: "Peak", value: String(format: "%.1f g", peakWeight))
                StudioReadoutChip(
                    title: "Temp",
                    value: machine.telemetry.temperature.map { String(format: "%.0f°C", $0) } ?? "—"
                )
                StudioReadoutChip(
                    title: "State",
                    value: machine.telemetry.state.rawValue.capitalized
                )
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var controls: some View {
        StudioCard {
            VStack(spacing: 12) {
                StudioSectionTitle(title: "Scale", detail: "Live from the machine", icon: "scalemass.fill")

                Button {
                    Task { await tare() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tare")
                                .font(.headline)
                            Text("Zeroes the machine, not just this screen")
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

                HStack(spacing: 10) {
                    secondaryButton(
                        showsGrams ? "Show ounces" : "Show grams",
                        icon: "arrow.left.arrow.right"
                    ) {
                        showsGrams.toggle()
                    }
                    secondaryButton("Reset peak", icon: "arrow.uturn.backward") {
                        peakWeight = weight
                    }
                }
            }
        }
    }

    private func secondaryButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var notes: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                StudioSectionTitle(title: "About this screen", icon: "info.circle")
                Text(
                    "Weight comes from the machine's own load cell, several times "
                        + "a second. Tare clears it on the machine. Unit switching "
                        + "is display-only and does not change the machine's own "
                        + "setting."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            }
        }
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
            row(message, icon: "checkmark.circle.fill", tint: StudioTheme.mint)
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
            .padding(15)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
