import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XBloomCore

struct SettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @Environment(SupabaseService.self) private var cloud
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(BrewSessionCoordinator.self) private var brewSession
    @State private var confirmingMachineStop = false
    @State private var machineStopMessage: String?
    @State private var showingGuide = false
    @State private var showingMachine = false

    var body: some View {
        ZStack {
            StudioBackground()
            Form {
                Section {
                    accountSummary
                    DisclosureGroup {
                        automaticSyncSettings.padding(.vertical, 8)
                    } label: {
                        settingsRow(icon: "arrow.triangle.2.circlepath", title: "Automatic sync",
                                    subtitle: syncSummary, tint: syncTint)
                    }
                    .tint(StudioTheme.accent)
                    .accessibilityIdentifier("settings.sync")
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR STUDIO")
                            .font(.caption2.weight(.semibold)).tracking(2)
                            .foregroundStyle(StudioTheme.accent)
                        Text("Make it yours.")
                            .font(.system(.largeTitle, design: .serif).weight(.regular))
                            .foregroundStyle(.white)
                        Text("Your coffee, your preferences.")
                            .font(.subheadline).foregroundStyle(StudioTheme.muted)
                    }
                    .textCase(nil)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)
                }
                .listRowBackground(StudioTheme.panel)

                Section("Your machine") {
                    Button { showingMachine = true } label: {
                        actionRow(icon: "antenna.radiowaves.left.and.right", title: "Bluetooth connection",
                                  subtitle: machine.isConnected ? "Connected to \(machine.machineName)" : "Connect and view live readings",
                                  tint: machine.isConnected ? StudioTheme.mint : StudioTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.machine")

                    Toggle(isOn: Binding(
                        get: { MachineFeedback.isSoundEnabled },
                        set: { enabled in
                            MachineFeedback.isSoundEnabled = enabled
                            if enabled { MachineFeedback.previewConnectionSound() }
                        }
                    )) {
                        settingsRow(icon: "speaker.wave.2", title: "Connection sound",
                                    subtitle: "A chime when your machine connects or disconnects", tint: StudioTheme.accent)
                    }
                    .tint(StudioTheme.mint)
                    .accessibilityIdentifier("settings.connectionSound")

                    settingsLink("Maintenance", icon: "wrench.and.screwdriver",
                                 subtitle: "Cleaning, calibration, and descaling", tint: StudioTheme.crema) { MaintenanceView() }
                    settingsLink("Diagnostics", icon: "waveform.path.ecg",
                                 subtitle: "Record and share Bluetooth traffic", tint: StudioTheme.warning) { MachineDiagnosticsView() }
                }
                .listRowBackground(StudioTheme.panel)

                Section("Coffee library") {
                    settingsLink("Brew history", icon: "clock.arrow.circlepath",
                                 subtitle: "Your cups, ratings, and feedback", tint: StudioTheme.accent) { HistoryView() }
                    settingsLink("Recipe transfer", icon: "square.and.arrow.up.on.square",
                                 subtitle: "Import and export recipe files", tint: StudioTheme.crema) { RecipeTransferView() }
                    settingsLink("Import recipe link", icon: "link",
                                 subtitle: "Preview a recipe before saving it", tint: StudioTheme.mint) { RecipeLinkImportView() }
                }
                .listRowBackground(StudioTheme.panel)

                Section {
                    Button { showingGuide = true } label: {
                        actionRow(icon: "book.closed", title: "App guide",
                                  subtitle: "Connect, brew, and explore your studio", tint: StudioTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.guide")
                    settingsLink("On-device storage", icon: "internaldrive",
                                 subtitle: "Offline library and storage usage", tint: StudioTheme.mint) { OnDeviceStorageView() }
                } header: {
                    Text("App & privacy")
                } footer: {
                    Label("Your library stays available offline. Signing in loads your account’s cloud recipes; changes then sync automatically.",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                        .padding(.top, 6)
                }
                .listRowBackground(StudioTheme.panel)

                Section {
                    machineStopRow
                } header: {
                    Text("Machine safety")
                } footer: {
                    Text("Stops a pour even if it was started on the machine or in another app.")
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                }
                .listRowBackground(StudioTheme.panel)

                Section {
                    VStack(spacing: 6) {
                        Text("xBloom").font(.system(.title3, design: .serif))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                            .font(.caption)
                    }
                    .foregroundStyle(StudioTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .scrollContentBackground(.hidden)
            .listSectionSpacing(24)
            .listRowSeparatorTint(StudioTheme.line)
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingGuide) {
            OnboardingView(isGuide: true) { showingGuide = false }
        }
        .sheet(isPresented: $showingMachine) { MachineConnectionPanel() }
    }

    private var accountSummary: some View {
        NavigationLink {
            AccountAIView()
        } label: {
            HStack(spacing: 14) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: cloud.isAuthenticated ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(cloud.isAuthenticated ? StudioTheme.mint : StudioTheme.accent)
                        .frame(width: 52, height: 60)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your account")
                        .font(.system(.title3, design: .serif).weight(.medium))
                        .foregroundStyle(.white)
                    Text(cloud.email ?? (cloud.isAuthenticated ? "Signed in" : "Guest mode · saved on this iPhone"))
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(cloud.isAuthenticated ? "Manage account & AI" : "Sign in for sync & AI")
                        .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.accent)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("settings.account")
    }

    private var syncSummary: String {
        if !cloud.isAuthenticated { return "Local library · sign in to sync" }
        if cloud.isSyncing { return "Syncing your library…" }
        if cloud.lastSyncError != nil { return "Saved on this iPhone · retry pending" }
        if cloud.syncState.hasPendingChanges { return "Changes waiting to sync" }
        return cloud.lastSyncAt == nil ? "Automatic sync is on" : "Your library is up to date"
    }

    private var syncTint: Color {
        cloud.lastSyncError != nil ? StudioTheme.warning : cloud.isAuthenticated ? StudioTheme.mint : StudioTheme.muted
    }

    private func settingsLink<Destination: View>(
        _ title: String, icon: String, subtitle: String, tint: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            settingsRow(icon: icon, title: title, subtitle: subtitle, tint: tint)
        }
    }

    private func settingsRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: icon, tint: tint, size: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(StudioTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func actionRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            settingsRow(icon: icon, title: title, subtitle: subtitle, tint: tint)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.muted)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var automaticSyncSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cloud.isAuthenticated
                ? "Syncs when you open the app and after you make changes. Offline changes upload when you reconnect."
                : "Sign in to load your cloud recipes and keep new changes in sync.")
                .font(.caption).foregroundStyle(StudioTheme.muted)
            if cloud.isAuthenticated {
                if cloud.lastSyncError != nil {
                    Text("Sync paused. Your changes are saved on this iPhone. We’ll retry automatically.")
                        .font(.caption).foregroundStyle(StudioTheme.warning)
                } else if let date = cloud.lastSyncAt {
                    Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                }
                Button {
                    Task { _ = try? await cloud.sync(in: modelContext) }
                } label: {
                    HStack {
                        Label(cloud.isSyncing ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
                        if cloud.isSyncing { ProgressView() }
                    }.frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(cloud.isSyncing)
            }
        }
    }

    private var machineStopRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                confirmingMachineStop = true
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemImage: "stop.circle", tint: StudioTheme.danger, size: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stop the machine now")
                            .font(.body.weight(.medium))
                            .foregroundStyle(StudioTheme.danger)
                        Text(
                            machine.isConnected
                                ? "Sends a stop to the xBloom, whatever started the brew"
                                : "Connect to the machine to send a stop"
                        )
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!machine.isConnected)
            .opacity(machine.isConnected ? 1 : 0.5)

            if let machineStopMessage {
                Text(machineStopMessage)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.muted)
            }
        }
        .confirmationDialog(
            "Stop the machine?",
            isPresented: $confirmingMachineStop,
            titleVisibility: .visible
        ) {
            Button("Stop the machine", role: .destructive) { stopMachine() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The xBloom stops pouring straight away. Whatever is in the cup stays there.")
        }
    }

    private func stopMachine() {
        do {
            try machine.stopBrew()
            // A session the app had detached from is over now. Clearing its
            // restore snapshot stops the next launch resurrecting a brew that
            // was just killed.
            brewSession.markCompleted()
            machineStopMessage = "Stop sent to the machine."
            MachineFeedback.acknowledged()
        } catch {
            machineStopMessage = error.localizedDescription
        }
    }

}

private extension UTType {
    static let xBloomRecipeLibrary = UTType(
        exportedAs: "coffee.xbloom.recipe-library",
        conformingTo: .json
    )
}

private struct RecipeLibraryTransferItem: Transferable {
    let archive: RecipeLibraryArchive

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .xBloomRecipeLibrary) { item in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(item.archive)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "xBloom Recipes \(formatter.string(from: item.archive.exportedAt)).xbloomrecipes"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

private struct RecipeTransferView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredRecipe.updatedAt, order: .reverse) private var storedRecipes: [StoredRecipe]
    @State private var showingImporter = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private var recipes: [Recipe] {
        storedRecipes.compactMap(\.recipe)
    }

    private var transferItem: RecipeLibraryTransferItem {
        RecipeLibraryTransferItem(archive: RecipeLibraryArchive(recipes: recipes))
    }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 15) {
                            IconBadge(systemImage: "arrow.left.arrow.right.circle.fill", tint: StudioTheme.crema, size: 58)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Move your recipe library")
                                    .font(.title2.weight(.bold))
                                Text("One portable file preserves every saved machine setting.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        StatusPill(
                            title: "\(recipes.count) recipe\(recipes.count == 1 ? "" : "s") ready",
                            color: StudioTheme.mint,
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .studioCard()

                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(
                            title: "Export",
                            subtitle: "Share with another iPhone using AirDrop, Messages, Mail, or Files"
                        )

                        ShareLink(
                            item: transferItem,
                            preview: SharePreview("xBloom recipe library", image: Image(systemName: "cup.and.saucer.fill"))
                        ) {
                            Label("Export all recipes", systemImage: "square.and.arrow.up.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(recipes.isEmpty)

                        Text("The export includes recipe names, bean links, hot or iced style, dose, grind settings, AI details, and every pour setting. Gemini keys and brew history are never included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .studioCard()

                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(
                            title: "Import",
                            subtitle: "Choose an xBloom recipe-library file received from another device"
                        )

                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import recipe library", systemImage: "square.and.arrow.down.fill")
                                .font(.headline)
                                .foregroundStyle(StudioTheme.crema)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.primary.opacity(0.045), in: Capsule())
                                .overlay {
                                    Capsule().stroke(StudioTheme.crema.opacity(0.62), lineWidth: 1.5)
                                }
                        }
                        .buttonStyle(.plain)

                        Label(
                            "Matching recipe IDs are updated. New IDs are added, so importing the same file again will not create duplicates.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .studioCard()

                    if let resultMessage {
                        Label(
                            resultMessage,
                            systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(resultIsError ? StudioTheme.warning : StudioTheme.mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Recipe Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.xBloomRecipeLibrary, .json],
            allowsMultipleSelection: false
        ) { result in
            importLibrary(result)
        }
    }

    @MainActor
    private func importLibrary(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let archive: RecipeLibraryArchive
            if let decoded = try? JSONDecoder().decode(RecipeLibraryArchive.self, from: data) {
                archive = decoded
            } else {
                archive = RecipeLibraryArchive(recipes: try JSONDecoder().decode([Recipe].self, from: data))
            }
            guard archive.schemaVersion <= RecipeLibraryArchive.currentSchemaVersion else {
                throw RecipeTransferError.newerFormat
            }

            var existingByID = Dictionary(uniqueKeysWithValues: storedRecipes.map { ($0.id, $0) })
            var added = 0
            var updated = 0
            var skipped = 0

            for recipe in archive.recipes {
                let hasBlockingError = RecipeValidator.validate(recipe).contains { $0.severity == .error }
                guard !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !recipe.pours.isEmpty,
                      !hasBlockingError else {
                    skipped += 1
                    continue
                }
                if let stored = existingByID[recipe.id] {
                    stored.update(with: recipe)
                    updated += 1
                } else {
                    let stored = StoredRecipe(recipe: recipe)
                    modelContext.insert(stored)
                    existingByID[recipe.id] = stored
                    added += 1
                }
            }
            try modelContext.save()
            resultIsError = false
            resultMessage = "Imported \(added) new and updated \(updated) recipe\(updated == 1 ? "" : "s")" + (skipped > 0 ? "; skipped \(skipped) unsafe or incomplete." : ".")
        } catch {
            resultIsError = true
            resultMessage = error.localizedDescription
        }
    }
}

private enum RecipeTransferError: LocalizedError {
    case newerFormat

    var errorDescription: String? {
        switch self {
        case .newerFormat:
            "This library was created by a newer xBloom app version. Update this app before importing it."
        }
    }
}

private struct OnDeviceStorageView: View {
    @Query(sort: \StoredBean.updatedAt, order: .reverse) private var beans: [StoredBean]
    @Query(sort: \StoredRecipe.updatedAt, order: .reverse) private var recipes: [StoredRecipe]
    @Query(sort: \StoredBrew.completedAt, order: .reverse) private var brews: [StoredBrew]

    private var activeBeans: Int {
        beans.lazy.filter { !$0.archived }.count
    }

    private var archivedBeans: Int {
        beans.count - activeBeans
    }

    private var savedContentBytes: Int64 {
        let beanBytes = beans.reduce(into: 0) { $0 += $1.payload.count }
        let recipeBytes = recipes.reduce(into: 0) { $0 += $1.payload.count }
        let brewBytes = brews.reduce(into: 0) { $0 += $1.payload.count }
        return Int64(beanBytes + recipeBytes + brewBytes)
    }

    private var savedContentSize: String {
        ByteCountFormatter.string(fromByteCount: savedContentBytes, countStyle: .file)
    }

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 15) {
                            IconBadge(systemImage: "iphone.gen3", tint: StudioTheme.mint, size: 58)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Stored on this iPhone")
                                    .font(.title2.weight(.bold))
                                Text("Your coffee library stays available without a server or internet connection.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Label("Local database ready", systemImage: "checkmark.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.mint)
                    }
                    .studioCard()

                    VStack(alignment: .leading, spacing: 16) {
                        StudioSectionTitle(
                            title: "Saved library",
                            subtitle: "Content currently managed by xBloom"
                        )

                        storageMetric(
                            icon: StudioSymbol.bean,
                            title: "Beans",
                            value: "\(beans.count)",
                            detail: archivedBeans == 0
                                ? "\(activeBeans) active"
                                : "\(activeBeans) active · \(archivedBeans) archived",
                            tint: StudioTheme.mint
                        )
                        Divider()
                        storageMetric(
                            icon: "list.bullet.rectangle.fill",
                            title: "Recipes",
                            value: "\(recipes.count)",
                            detail: "Manual and AI-created",
                            tint: StudioTheme.accent
                        )
                        Divider()
                        storageMetric(
                            icon: "clock.arrow.circlepath",
                            title: "Brew sessions",
                            value: "\(brews.count)",
                            detail: "History and extraction telemetry",
                            tint: StudioTheme.crema
                        )
                    }
                    .studioCard()

                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(title: "Storage details")

                        HStack {
                            Label("Saved content", systemImage: "externaldrive.fill")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(savedContentSize)
                                .font(.headline.monospacedDigit())
                        }

                        Text("This is the size of your saved bean, recipe, and brew records. iOS may use a little additional space for the database and app preferences.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        NavigationLink {
                            HistoryView()
                        } label: {
                            Label("Open brew history", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                    .studioCard()

                    Label(
                        "Cloud sync keeps a private copy in Supabase while this on-device database remains available offline.",
                        systemImage: "icloud.and.arrow.up.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("On-device Storage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func storageMetric(
        icon: String,
        title: String,
        value: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: icon, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}
