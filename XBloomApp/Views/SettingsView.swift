import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XBloomCore

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SupabaseService.self) private var cloud
    @Environment(XBloomBLEClient.self) private var machine
    @Environment(BrewSessionCoordinator.self) private var brewSession
    @State private var confirmingMachineStop = false
    @State private var machineStopMessage: String?

    var body: some View {
        ZStack {
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 22) {
                    HStack(spacing: 15) {
                        IconBadge(systemImage: "cup.and.saucer.fill", tint: StudioTheme.crema, size: 58)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("xBloom companion")
                                .font(.title2.weight(.bold))
                            Text("Private, local, and made for your coffee")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .studioCard()

                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(title: "Account")
                        NavigationLink {
                            AccountAIView()
                        } label: {
                            settingsRow(
                                icon: "person.crop.circle.fill",
                                title: "Account & AI",
                                subtitle: cloud.isAuthenticated
                                    ? (cloud.email ?? "Signed in")
                                    : "Sign in for sync and AI",
                                tint: cloud.isAuthenticated ? StudioTheme.mint : StudioTheme.warning,
                                isComplete: cloud.isAuthenticated
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                    .studioCard()

                    VStack(alignment: .leading, spacing: 14) {
                        StudioSectionTitle(title: "Library & privacy")
                        NavigationLink {
                            HistoryView()
                        } label: {
                            settingsRow(
                                icon: "clock.arrow.circlepath",
                                title: "Brew history",
                                subtitle: "Sessions and telemetry",
                                tint: StudioTheme.accent
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Divider()

                        NavigationLink {
                            OnDeviceStorageView()
                        } label: {
                            settingsRow(
                                icon: "internaldrive.fill",
                                title: "On-device storage",
                                subtitle: "Beans, recipes, history, and preferences",
                                tint: StudioTheme.mint
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Divider()

                        NavigationLink {
                            RecipeTransferView()
                        } label: {
                            settingsRow(
                                icon: "square.and.arrow.up.on.square.fill",
                                title: "Recipe transfer",
                                subtitle: "Export or import a complete library",
                                tint: StudioTheme.crema
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Divider()

                        Toggle(isOn: Binding(
                            get: { MachineFeedback.isSoundEnabled },
                            set: { enabled in
                                MachineFeedback.isSoundEnabled = enabled
                                if enabled { MachineFeedback.previewConnectionSound() }
                            }
                        )) {
                            HStack(spacing: 14) {
                                IconBadge(systemImage: "speaker.wave.2.fill", tint: StudioTheme.accent, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Connection sound").font(.headline)
                                    Text("Chime when the machine pairs or drops")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(StudioTheme.mint)

                        Divider()

                        NavigationLink {
                            MaintenanceView()
                        } label: {
                            settingsRow(
                                icon: "wrench.and.screwdriver.fill",
                                title: "Maintenance",
                                subtitle: "Brush, tablets, calibration, and descaling",
                                tint: StudioTheme.crema
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Divider()

                        NavigationLink {
                            MachineDiagnosticsView()
                        } label: {
                            settingsRow(
                                icon: "waveform.path.ecg",
                                title: "Machine diagnostics",
                                subtitle: "Record and share Bluetooth traffic",
                                tint: StudioTheme.warning
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Divider()

                        machineStopRow
                    }
                    .studioCard()

                    Text("xBloom Native · Version 0.1")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The last resort for a machine that is pouring when nothing in the app is
    /// showing a brew — one started from the xBloom's own panel or another app,
    /// or a session this app lost track of while the link was down.
    ///
    /// Deliberately not conditional on the app believing a brew is running: the
    /// case it exists for is precisely the one where the app does not know.
    private var machineStopRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                confirmingMachineStop = true
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemImage: "stop.circle.fill", tint: StudioTheme.danger, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stop the machine now")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(
                            machine.isConnected
                                ? "Sends a stop to the xBloom, whatever started the brew"
                                : "Connect to the machine to send a stop"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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

    /// `isComplete` puts a tick on the row, so a screen that has already been
    /// dealt with says so without being opened.
    private func settingsRow(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color,
        isComplete: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: icon, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(StudioTheme.mint)
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
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
                            icon: "leaf.fill",
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
