import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0
    @State private var seedError: String?
    @State private var isLaunching = true

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView(selectedTab: $selectedTab)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(0)
                RecipesView()
                    .tabItem { Label("Recipes", systemImage: "list.bullet.rectangle") }
                    .tag(1)
                BrewView()
                    .tabItem { Label("Brew", systemImage: "cup.and.saucer.fill") }
                    .tag(2)
                BeansView()
                    .tabItem { Label("Beans", systemImage: "leaf") }
                    .tag(3)
                NavigationStack {
                    HistoryView()
                }
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                    .tag(4)
            }

            if isLaunching {
                StartupLoadingView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .tint(AppTheme.coffee)
        .preferredColorScheme(.dark)
        .task {
            do {
                try LocalLibrary.seedIfNeeded(in: modelContext)
                #if DEBUG
                try LocalLibrary.seedHistoryPreviewIfRequested(in: modelContext)
                #endif
            } catch {
                seedError = error.localizedDescription
            }
            await Task.yield()
            withAnimation(.easeOut(duration: 0.4)) {
                isLaunching = false
            }
        }
        .alert("Local database error", isPresented: .constant(seedError != nil)) {
            Button("OK") { seedError = nil }
        } message: {
            Text(seedError ?? "")
        }
    }
}

private struct StartupLoadingView: View {
    var body: some View {
        ZStack {
            StudioBackground()
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(StudioTheme.panel)
                        .frame(width: 118, height: 118)
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(StudioTheme.accent.opacity(0.26), lineWidth: 1)
                        }
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [StudioTheme.mint, StudioTheme.accent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.pulse.byLayer, options: .repeating)
                }

                VStack(spacing: 7) {
                    Text("xBloom")
                        .font(.largeTitle.weight(.bold))
                    Text("Preparing your coffee studio")
                        .font(.subheadline)
                        .foregroundStyle(StudioTheme.muted)
                }

                ProgressView()
                    .controlSize(.small)
                    .tint(StudioTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("xBloom is preparing your coffee studio")
    }
}

struct MachineToolbar: ToolbarContent {
    @Environment(XBloomBLEClient.self) private var machine

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                machine.isConnected ? machine.disconnect() : machine.connect()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(machine.isConnected ? AppTheme.sage : .secondary)
                        .frame(width: 7, height: 7)
                    Text(machine.isConnected ? "Connected" : "Connect")
                        .font(.caption.weight(.bold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
            }
            .accessibilityLabel(machine.isConnected ? "Disconnect \(machine.machineName)" : "Connect xBloom")
        }
    }
}
