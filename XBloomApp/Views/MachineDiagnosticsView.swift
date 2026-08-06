import SwiftUI
import XBloomCore

/// Records the machine's Bluetooth traffic so brew behaviour can be read from
/// what this machine actually sends rather than from a protocol reference
/// written against someone else's firmware.
struct MachineDiagnosticsView: View {
    @Environment(XBloomBLEClient.self) private var machine
    @State private var showingTranscript = false

    private var log: MachineTrafficLog { machine.trafficLog }

    private var summary: [(command: UInt16, count: Int, firstOffset: TimeInterval)] {
        log.receivedCommandSummary()
    }

    private var transcript: String { log.transcript() }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 22) {
                    instructions
                    controls
                    if !summary.isEmpty { identifierSummary }
                    if !log.entries.isEmpty { recentFrames }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("Machine diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTranscript) {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Text(transcript)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("Traffic transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingTranscript = false }
                    }
                }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader(title: "Capture a real brew")
            Text(
                """
                1. Connect to the machine.
                2. Tap Start recording.
                3. Run one complete brew, start to finish.
                4. Tap Stop recording, then share the transcript.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(
                "The transcript shows every frame with its timing, so the pours, "
                    + "rests, and the point where extraction really begins can be "
                    + "read directly instead of guessed."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .appCard()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader(title: "Recording")

            HStack(spacing: 10) {
                statusPill(
                    log.isRecording ? "Recording" : "Idle",
                    tint: log.isRecording ? .red : .secondary
                )
                statusPill("\(log.entries.count) frames", tint: AppTheme.coffee)
                statusPill(
                    machine.isConnected ? "Connected" : machine.connectionState.rawValue.capitalized,
                    tint: machine.isConnected ? AppTheme.sage : .orange
                )
            }

            if log.isRecording {
                Button {
                    machine.stopTrafficRecording()
                } label: {
                    Label("Stop recording", systemImage: "stop.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    machine.startTrafficRecording()
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coffee)
            }

            if !log.entries.isEmpty {
                HStack(spacing: 10) {
                    ShareLink(item: transcript) {
                        Label("Share transcript", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showingTranscript = true
                    } label: {
                        Label("View", systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    machine.clearTrafficLog()
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }
        }
        .appCard()
    }

    private var identifierSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader(title: "Identifiers received")
            Text("In the order they first appeared.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(summary, id: \.command) { row in
                HStack(spacing: 10) {
                    Text(String(row.command))
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                    Text(name(for: row.command))
                        .font(.footnote)
                        .foregroundStyle(
                            XBloomNotification(rawValue: row.command) == nil ? .orange : .primary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Text("×\(row.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1fs", row.firstOffset))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
        .appCard()
    }

    private var recentFrames: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader(title: "Latest frames")
            ForEach(log.entries.suffix(60).reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(entry.direction.rawValue)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(tint(for: entry.direction))
                        Text(entry.commandName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.payloadHex.isEmpty {
                        Text(entry.payloadHex)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                Divider()
            }
        }
        .appCard()
    }

    private func name(for command: UInt16) -> String {
        guard let known = XBloomNotification(rawValue: command) else {
            return "not in the reference"
        }
        return String(describing: known)
    }

    private func tint(for direction: MachineTrafficEntry.Direction) -> Color {
        switch direction {
        case .sent: AppTheme.coffee
        case .received: AppTheme.sage
        case .unparsed: .orange
        case .note: .secondary
        }
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(tint.opacity(0.13), in: Capsule())
    }
}
