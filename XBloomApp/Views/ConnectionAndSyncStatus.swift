import SwiftData
import SwiftUI

struct ConnectionAndSyncStatus: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(SupabaseService.self) private var cloud

    private var connecting: Bool {
        [.scanning, .connecting, .subscribing].contains(machine.connectionState)
    }
    private var syncTitle: String {
        if !cloud.isAuthenticated { return "Saved on this iPhone" }
        if cloud.isSyncing { return "Syncing your library" }
        if cloud.lastSyncError != nil { return "Sync needs attention" }
        if cloud.syncState.hasPendingChanges { return "Waiting to sync" }
        return "Library synced"
    }
    private var syncDetail: String {
        if !cloud.isAuthenticated { return "Sign in to sync across devices." }
        if let error = cloud.lastSyncError { return "Your local library is still available. \(error)" }
        if cloud.syncState.hasPendingChanges { return "Local changes are waiting for a completed sync." }
        if let date = cloud.lastSyncAt { return "Last synced \(date.formatted(date: .omitted, time: .shortened))." }
        return "Your library is available on this phone."
    }

    var body: some View {
        StudioCard {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: machine.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(machine.isConnected ? StudioTheme.mint : StudioTheme.warning)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(machine.isConnected ? "Machine connected" : connecting ? "Connecting to xBloom…" : "Machine disconnected")
                            .font(.subheadline.weight(.semibold))
                        Text(machine.isConnected ? "Ready over Bluetooth" : "Keep the machine awake and your phone nearby.")
                            .font(.caption).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer(minLength: 0)
                    if connecting { ProgressView() }
                    else if !machine.isConnected {
                        Button("Connect") { machine.connect() }.font(.subheadline.bold())
                    }
                }
                Divider().overlay(StudioTheme.raised)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: cloud.isAuthenticated ? "icloud" : "iphone")
                        .foregroundStyle(cloud.lastSyncError == nil ? StudioTheme.mint : StudioTheme.warning)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(syncTitle).font(.subheadline.weight(.semibold))
                        Text(syncDetail).font(.caption).foregroundStyle(StudioTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if cloud.isSyncing { ProgressView() }
                    else if cloud.isAuthenticated {
                        Button(cloud.lastSyncError == nil ? "Sync" : "Retry") {
                            Task { _ = try? await cloud.sync(in: modelContext) }
                        }.font(.subheadline.bold())
                    } else {
                        NavigationLink("Account") { SettingsView() }.font(.subheadline.bold())
                    }
                }
            }
        }
    }
}
