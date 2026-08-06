import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XBloomCore

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SupabaseService.self) private var cloud
    @Environment(GeminiService.self) private var gemini
    @State private var email = ""
    @State private var password = ""
    @State private var model = ""
    @State private var statusMessage: String?
    @State private var isTesting = false
    @State private var isAuthenticating = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 22) {
                    HStack(spacing: 15) {
                        IconBadge(systemImage: "cup.and.saucer.fill", tint: AppTheme.crema, size: 58)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("xBloom companion")
                                .font(.title2.weight(.bold))
                            Text("Private, local, and made for your coffee")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .appCard()

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            AppSectionHeader(
                                title: "Cloud & Gemini",
                                subtitle: "Supabase backup and server-side AI"
                            )
                            Spacer()
                            StatusPill(
                                title: cloud.isAuthenticated ? "Connected" : "Setup",
                                color: cloud.isAuthenticated ? AppTheme.sage : .orange,
                                systemImage: cloud.isAuthenticated ? "checkmark.circle.fill" : "icloud.slash"
                            )
                        }

                        if cloud.isAuthenticated {
                            Label(cloud.email ?? "Supabase account", systemImage: "person.crop.circle.fill")
                                .font(.subheadline.weight(.semibold))

                            HStack {
                                Image(systemName: "cpu").foregroundStyle(.secondary)
                                TextField("Gemini model", text: $model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            .padding(13)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))

                            HStack {
                                Button("Save model") {
                                    gemini.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                                    statusMessage = "Model preference saved."
                                }
                                Button {
                                    testGemini()
                                } label: {
                                    Label(isTesting ? "Testing…" : "Test AI", systemImage: "network")
                                }
                                .disabled(isTesting)
                                Spacer()
                                Button("Sign out", role: .destructive) {
                                    Task { await signOut() }
                                }
                            }
                            .font(.subheadline.weight(.semibold))

                            Button {
                                Task { await syncNow() }
                            } label: {
                                Label(
                                    cloud.isSyncing ? "Syncing…" : "Sync now",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .disabled(cloud.isSyncing)
                        } else {
                            VStack(spacing: 10) {
                                TextField("Email", text: $email)
                                    .textContentType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                SecureField("Password (8+ characters)", text: $password)
                                    .textContentType(.password)
                            }
                            .padding(13)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))

                            HStack {
                                Button("Sign in") {
                                    Task { await authenticate(createAccount: false) }
                                }
                                .buttonStyle(PrimaryActionButtonStyle())
                                Button("Create account") {
                                    Task { await authenticate(createAccount: true) }
                                }
                                .disabled(isAuthenticating)
                            }
                        }

                        if isTesting { ProgressView().frame(maxWidth: .infinity) }
                        if isAuthenticating || cloud.isSyncing {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                        if let message = statusMessage ?? cloud.statusMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(message.contains("failed") ? .orange : .secondary)
                        }

                        Label(
                            "Your library stays on this iPhone and syncs to your private Supabase account. Gemini requests run through an authenticated Edge Function; its API key is never stored in the app.",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .appCard()

                    VStack(alignment: .leading, spacing: 14) {
                        AppSectionHeader(title: "Library & privacy")
                        NavigationLink {
                            HistoryView()
                        } label: {
                            settingsRow(
                                icon: "clock.arrow.circlepath",
                                title: "Brew history",
                                subtitle: "Sessions and telemetry",
                                tint: AppTheme.coffee
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
                                tint: AppTheme.sage
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
                                tint: AppTheme.crema
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                    .appCard()

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
        .onAppear { model = gemini.model }
        .onDisappear {
            testTask?.cancel()
            testTask = nil
        }
    }

    private func settingsRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: icon, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func authenticate(createAccount: Bool) async {
        guard password.count >= 8 else {
            statusMessage = "Use a password with at least 8 characters."
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            if createAccount {
                try await cloud.signUp(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
            } else {
                try await cloud.signIn(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
            }
            password = ""
            statusMessage = cloud.statusMessage
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func signOut() async {
        do {
            try await cloud.signOut()
            statusMessage = cloud.statusMessage
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func syncNow() async {
        do {
            let summary = try await cloud.sync(in: modelContext)
            statusMessage = "Synced \(summary.beans) beans, \(summary.recipes) recipes, and \(summary.brews) brews."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testGemini() {
        testTask?.cancel()
        testTask = Task { @MainActor in
            isTesting = true
            defer { isTesting = false }
            do {
                try await gemini.testConnection()
                try Task.checkCancellation()
                statusMessage = "Gemini connection succeeded."
            } catch is CancellationError {
                return
            } catch {
                statusMessage = error.localizedDescription
            }
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
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 15) {
                            IconBadge(systemImage: "arrow.left.arrow.right.circle.fill", tint: AppTheme.crema, size: 58)
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
                            color: AppTheme.sage,
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .appCard()

                    VStack(alignment: .leading, spacing: 14) {
                        AppSectionHeader(
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
                    .appCard()

                    VStack(alignment: .leading, spacing: 14) {
                        AppSectionHeader(
                            title: "Import",
                            subtitle: "Choose an xBloom recipe-library file received from another device"
                        )

                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import recipe library", systemImage: "square.and.arrow.down.fill")
                                .font(.headline)
                                .foregroundStyle(AppTheme.crema)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.primary.opacity(0.045), in: Capsule())
                                .overlay {
                                    Capsule().stroke(AppTheme.crema.opacity(0.62), lineWidth: 1.5)
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
                    .appCard()

                    if let resultMessage {
                        Label(
                            resultMessage,
                            systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(resultIsError ? .orange : AppTheme.sage)
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
            AppBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 15) {
                            IconBadge(systemImage: "iphone.gen3", tint: AppTheme.sage, size: 58)
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
                            .foregroundStyle(AppTheme.sage)
                    }
                    .appCard()

                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionHeader(
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
                            tint: AppTheme.sage
                        )
                        Divider()
                        storageMetric(
                            icon: "list.bullet.rectangle.fill",
                            title: "Recipes",
                            value: "\(recipes.count)",
                            detail: "Manual and AI-created",
                            tint: AppTheme.coffee
                        )
                        Divider()
                        storageMetric(
                            icon: "clock.arrow.circlepath",
                            title: "Brew sessions",
                            value: "\(brews.count)",
                            detail: "History and extraction telemetry",
                            tint: AppTheme.crema
                        )
                    }
                    .appCard()

                    VStack(alignment: .leading, spacing: 14) {
                        AppSectionHeader(title: "Storage details")

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
                    .appCard()

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
