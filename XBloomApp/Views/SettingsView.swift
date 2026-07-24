import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(GeminiService.self) private var gemini
    @State private var apiKey = ""
    @State private var model = ""
    @State private var statusMessage: String?
    @State private var isTesting = false
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
                            AppSectionHeader(title: "Gemini intelligence", subtitle: "Bean import and recipe creation")
                            Spacer()
                            StatusPill(
                                title: gemini.hasAPIKey ? "Ready" : "Setup",
                                color: gemini.hasAPIKey ? AppTheme.sage : .orange,
                                systemImage: gemini.hasAPIKey ? "checkmark.circle.fill" : "key.fill"
                            )
                        }

                        VStack(spacing: 10) {
                            HStack {
                                Image(systemName: "key.fill").foregroundStyle(.secondary)
                                SecureField(gemini.hasAPIKey ? "API key saved — enter to replace" : "Gemini API key", text: $apiKey)
                                    .textContentType(.password)
                            }
                            .padding(13)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))

                            HStack {
                                Image(systemName: "cpu").foregroundStyle(.secondary)
                                TextField("Model", text: $model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            .padding(13)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                        }

                        Button("Save Gemini settings") {
                            saveGeminiSettings()
                        }
                        .buttonStyle(PrimaryActionButtonStyle())

                        HStack {
                            Button {
                                testGemini()
                            } label: {
                                Label(isTesting ? "Testing…" : "Test connection", systemImage: "network")
                            }
                            .disabled(!gemini.hasAPIKey || isTesting)

                            Spacer()

                            Button("Remove key", role: .destructive) {
                                gemini.removeAPIKey()
                                statusMessage = "API key removed."
                            }
                            .disabled(!gemini.hasAPIKey)
                        }
                        .font(.subheadline.weight(.semibold))

                        if isTesting { ProgressView().frame(maxWidth: .infinity) }
                        if let statusMessage {
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundStyle(statusMessage.contains("succeeded") || statusMessage.contains("securely") ? AppTheme.sage : .secondary)
                        }

                        Label(
                            "Your key stays in iOS Keychain. Requests go from this iPhone directly to Gemini.",
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

    private func saveGeminiSettings() {
        do {
            if !apiKey.isEmpty { try gemini.saveAPIKey(apiKey) }
            gemini.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKey = ""
            statusMessage = "Saved securely in Keychain."
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
                        "Your Gemini key is kept separately in iOS Keychain and is never included in the database size above.",
                        systemImage: "key.fill"
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
