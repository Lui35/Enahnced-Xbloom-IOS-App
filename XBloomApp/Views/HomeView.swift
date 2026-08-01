import SwiftData
import SwiftUI

struct HomeView: View {
    @Binding var selectedTab: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Query private var history: [StoredBrew]
    @State private var activeBeans = 0
    @State private var recipeCount = 0

    init(selectedTab: Binding<Int>) {
        _selectedTab = selectedTab
        var descriptor = FetchDescriptor<StoredBrew>(
            sortBy: [SortDescriptor(\StoredBrew.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _history = Query(descriptor)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    LazyVStack(spacing: 24) {
                        welcomeHeader
                        machineHero
                        libraryOverview
                        recentBrew
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                MachineToolbar()
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .onAppear { refreshLibraryCounts() }
        }
    }

    private var welcomeHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Good \(dayPart)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Ready for something\nexceptional?")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .tracking(-0.7)
            }
            Spacer()
            Image(systemName: "leaf.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.crema)
                .frame(width: 52, height: 52)
                .background(AppTheme.espresso, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: AppTheme.espresso.opacity(0.22), radius: 15, y: 7)
        }
        .padding(.top, 8)
    }

    private var machineHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(machine.machineName)
                        .font(.title2.weight(.bold))
                    Text(machineSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
                StatusPill(
                    title: machine.connectionState.rawValue.capitalized,
                    color: machine.isConnected ? Color(red: 0.53, green: 0.93, blue: 0.68) : .white.opacity(0.78),
                    systemImage: machine.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
                )
            }

            if machine.isConnected {
                HStack(spacing: 10) {
                    heroMetric("Weight", machine.telemetry.weight, "g")
                    heroMetric("Water", machine.telemetry.waterVolume, "ml")
                    heroMetric("Temp", machine.telemetry.temperature, "°")
                }
                Text(machine.telemetry.state.rawValue.capitalized)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.crema)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(AppTheme.crema)
                    Text("Keep your phone near the machine. Connection and brewing happen directly over Bluetooth.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if machine.isConnected {
                HStack(spacing: 10) {
                    Button {
                        Task { await machine.testConnection() }
                    } label: {
                        Label(
                            machine.diagnosticState == .testing ? "Testing…" : "Test machine",
                            systemImage: "wave.3.right"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(AppTheme.espresso)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(machine.diagnosticState == .testing)
                    .buttonStyle(.plain)

                    Button {
                        machine.disconnect()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 48, height: 48)
                            .foregroundStyle(.white)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    machine.connect()
                } label: {
                    Label("Connect xBloom", systemImage: "bolt.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(AppTheme.espresso)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            diagnosticMessage

            if let error = machine.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 1, green: 0.67, blue: 0.60))
            }
        }
        .padding(22)
        .foregroundStyle(.white)
        .background(AppTheme.heroGradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 180, height: 180)
                .offset(x: 55, y: -75)
                .allowsHitTesting(false)
        }
        .shadow(color: AppTheme.espresso.opacity(0.22), radius: 24, y: 12)
    }

    private var libraryOverview: some View {
        VStack(spacing: 14) {
            AppSectionHeader(title: "Your coffee", subtitle: "Everything stays on this iPhone")
            HStack(spacing: 12) {
                libraryButton(title: "Beans", value: activeBeans, icon: "leaf.fill", tint: AppTheme.sage, tab: 3)
                libraryButton(title: "Recipes", value: recipeCount, icon: "list.bullet.rectangle.fill", tint: AppTheme.crema, tab: 1)
            }
            Button {
                selectedTab = 2
            } label: {
                Label("Choose a recipe & brew", systemImage: "cup.and.saucer.fill")
            }
            .buttonStyle(PrimaryActionButtonStyle())
        }
    }

    private func refreshLibraryCounts() {
        let activeDescriptor = FetchDescriptor<StoredBean>(
            predicate: #Predicate { !$0.archived }
        )
        activeBeans = (try? modelContext.fetchCount(activeDescriptor)) ?? activeBeans
        recipeCount = (try? modelContext.fetchCount(FetchDescriptor<StoredRecipe>())) ?? recipeCount
    }

    private var recentBrew: some View {
        VStack(spacing: 14) {
            AppSectionHeader(title: "Recent activity")
            if let last = history.first {
                NavigationLink {
                    BrewHistoryDetailView(brew: last)
                } label: {
                    HStack(spacing: 15) {
                        IconBadge(systemImage: "waveform.path.ecg", tint: AppTheme.coffee, size: 50)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(last.recipeName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(last.completedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .appCard()
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 15) {
                    IconBadge(systemImage: "clock.arrow.circlepath", tint: .secondary, size: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No brews yet").font(.headline)
                        Text("Your first completed brew will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .appCard()
            }

            NavigationLink {
                HistoryView()
            } label: {
                Text("View full brew history")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func libraryButton(title: String, value: Int, icon: String, tint: Color, tab: Int) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    IconBadge(systemImage: icon, tint: tint)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                Text("\(value)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard()
        }
        .buttonStyle(.plain)
    }

    private func heroMetric(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(value.map { "\(String(format: "%.1f", $0))\(unit)" } ?? "—")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var machineSubtitle: String {
        switch machine.connectionState {
        case .connected: "Live telemetry is ready"
        case .subscribing: "Opening the machine command channel…"
        case .connecting: "Pairing securely over Bluetooth…"
        case .scanning: "Searching for your machine…"
        case .unavailable: "Bluetooth is currently unavailable"
        case .disconnected: "Your personal coffee station"
        }
    }

    @ViewBuilder
    private var diagnosticMessage: some View {
        switch machine.diagnosticState {
        case .idle:
            if machine.isConnected {
                Label("Test briefly vibrates the scale tray and waits for a machine response.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
        case .testing:
            Label("Sending a safe movement test…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.crema)
        case .passed:
            Label("Machine responded — command channel verified.", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.53, green: 0.93, blue: 0.68))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color(red: 1, green: 0.67, blue: 0.60))
        }
    }

    private var dayPart: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "morning"
        case 12..<18: "afternoon"
        default: "evening"
        }
    }
}
