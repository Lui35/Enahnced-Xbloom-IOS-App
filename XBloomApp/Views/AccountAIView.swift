import SwiftData
import SwiftUI
import XBloomCore

/// The account, and the model that answers for it.
///
/// Both used to sit in one long card at the top of Settings — sign-in fields,
/// a model box, a test button, a sync button and a sign-out button, all on
/// screen at once whether or not you were signed in. They are one subject and
/// they belong on their own screen, where Settings can say in a line whether
/// you are signed in and leave it at that.
struct AccountAIView: View {
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
            StudioBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    if !SupabaseService.isConfigured {
                        unconfiguredCard
                    } else if cloud.isAuthenticated {
                        accountCard
                        modelCard
                        syncCard
                    } else {
                        signInCard
                    }
                    if let message = statusMessage ?? cloud.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(
                                message.localizedCaseInsensitiveContains("fail")
                                    ? StudioTheme.warning
                                    : StudioTheme.muted
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    privacyNote
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Account & AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StudioTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear { model = gemini.model }
        .onDisappear {
            testTask?.cancel()
            testTask = nil
        }
    }

    /// This build has no backend, which is a supported way to run the app —
    /// not a failure to report as one.
    private var unconfiguredCard: some View {
        StudioCard(accent: StudioTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "No project configured",
                    detail: "Local only",
                    icon: "icloud.slash"
                )
                Text(
                    "This build was made without a Supabase project, so there is no "
                        + "account to sign in to and the AI features are unavailable."
                )
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
                Text(
                    "Everything else works: your beans, recipes and history live on "
                        + "this iPhone, and the machine is driven over Bluetooth. To add "
                        + "sync and AI, put your own project into Secrets.xcconfig and "
                        + "rebuild — INSTALLATION.md walks through it."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)
            }
        }
    }

    // MARK: - Signed in

    private var accountCard: some View {
        StudioCard(accent: StudioTheme.mint) {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    IconBadge(systemImage: "person.crop.circle.fill", tint: StudioTheme.mint, size: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cloud.email ?? "Supabase account")
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("Signed in")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.mint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(StudioTheme.mint)
                }

                Button("Sign out", role: .destructive) {
                    Task { await signOut() }
                }
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(StudioTheme.raised, in: Capsule())
                .buttonStyle(.plain)
                .foregroundStyle(StudioTheme.danger)
            }
        }
    }

    private var modelCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "AI model",
                    detail: isModelValid ? nil : "Not a valid name",
                    icon: "cpu"
                )

                HStack {
                    TextField("gemini-…", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                    if model != gemini.model {
                        Button("Save") { saveModel() }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isModelValid ? StudioTheme.accent : StudioTheme.muted)
                            .disabled(!isModelValid)
                    }
                }
                .padding(13)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                // The Edge Function only accepts names matching its own pattern
                // and forwards them to Google. A name it refuses fails at the
                // server with nothing useful to show, so it is refused here.
                if !isModelValid {
                    Label(
                        "The server only accepts Gemini model names, like \(GeminiService.defaultModel).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(StudioTheme.warning)
                }

                HStack(spacing: 10) {
                    Button {
                        testGemini()
                    } label: {
                        Label(isTesting ? "Testing…" : "Test the connection", systemImage: "network")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(StudioTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting)

                    if model != GeminiService.defaultModel {
                        Button("Default") {
                            model = GeminiService.defaultModel
                            saveModel()
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioTheme.muted)
                        .frame(height: 44)
                        .padding(.horizontal, 14)
                        .background(StudioTheme.raised, in: Capsule())
                        .buttonStyle(.plain)
                    }
                }

                if isTesting { ProgressView().frame(maxWidth: .infinity) }

                Text(
                    "Bean imports, recipe generation, and recipe enhancement all run "
                        + "through this model."
                )
                .font(.caption)
                .foregroundStyle(StudioTheme.muted)

                Divider()

                Toggle(isOn: Binding(
                    get: { gemini.usesBrewingReference },
                    set: { gemini.usesBrewingReference = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Brewing reference").font(.subheadline.weight(.semibold))
                        Text(
                            "Send the grind, flow, pattern and agitation guide with every "
                                + "recipe request. Turn it off to generate the same bean "
                                + "both ways and compare."
                        )
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                    }
                }
                .tint(StudioTheme.mint)
            }
        }
    }

    private var syncCard: some View {
        StudioCard(accent: StudioTheme.crema) {
            VStack(alignment: .leading, spacing: 12) {
                StudioSectionTitle(
                    title: "Cloud sync",
                    detail: "Beans, recipes, and history",
                    icon: "arrow.triangle.2.circlepath"
                )
                Button {
                    Task { await syncNow() }
                } label: {
                    Label(cloud.isSyncing ? "Syncing…" : "Sync now", systemImage: "icloud.and.arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(StudioTheme.crema, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(cloud.isSyncing)
                if cloud.isSyncing { ProgressView().frame(maxWidth: .infinity) }
            }
        }
    }

    // MARK: - Signed out

    private var signInCard: some View {
        StudioCard(accent: StudioTheme.warning) {
            VStack(alignment: .leading, spacing: 13) {
                StudioSectionTitle(
                    title: "Sign in",
                    detail: "For sync and AI",
                    icon: "person.crop.circle.badge.plus"
                )

                VStack(spacing: 10) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Divider()
                    SecureField("Password (8+ characters)", text: $password)
                        .textContentType(.password)
                }
                .font(.subheadline)
                .padding(13)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    Task { await authenticate(createAccount: false) }
                } label: {
                    Text(isAuthenticating ? "Signing in…" : "Sign in")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(StudioTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isAuthenticating)

                Button {
                    Task { await authenticate(createAccount: true) }
                } label: {
                    Text("Create an account")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(StudioTheme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .disabled(isAuthenticating)

                if isAuthenticating { ProgressView().frame(maxWidth: .infinity) }
            }
        }
    }

    private var privacyNote: some View {
        StudioCard {
            Label(
                "Your library stays on this iPhone and syncs to your own Supabase "
                    + "account. AI requests run through an authenticated Edge Function, "
                    + "so the provider key is never in the app.",
                systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(StudioTheme.muted)
        }
    }

    // MARK: - Work

    private var isModelValid: Bool {
        GeminiService.isValidModelName(model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func saveModel() {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GeminiService.isValidModelName(trimmed) else { return }
        gemini.model = trimmed
        model = trimmed
        statusMessage = "Model set to \(trimmed)."
        MachineFeedback.acknowledged()
    }

    private func authenticate(createAccount: Bool) async {
        guard password.count >= 8 else {
            statusMessage = "Use a password with at least 8 characters."
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if createAccount {
                try await cloud.signUp(email: address, password: password)
            } else {
                try await cloud.signIn(email: address, password: password)
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
            statusMessage = "Synced \(summary.beans) beans, \(summary.recipes) recipes, "
                + "and \(summary.brews) brews."
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
                statusMessage = "The model answered."
            } catch is CancellationError {
                return
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
