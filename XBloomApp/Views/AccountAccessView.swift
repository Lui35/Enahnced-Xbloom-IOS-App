import AuthenticationServices
import CryptoKit
import SwiftUI

/// One account form for onboarding and Settings, with native autofill and focus handling.
struct AccountAccessView: View {
    @Environment(SupabaseService.self) private var cloud
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compactBenefits = false
    private enum Field: Hashable { case email, password, confirmation }
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var messageFocused: Bool
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var createsAccount = false
    @State private var revealsPassword = false
    @State private var isAuthenticating = false
    @State private var attemptedSubmission = false
    @State private var visitedFields: Set<Field> = []
    @State private var nonce: String?
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !compactBenefits {
                Text("Your coffee, wherever you go.")
                    .font(.title2.weight(.semibold)).fontDesign(.serif)
            }
            HStack(spacing: 16) {
                benefitChip("icloud", "Cloud sync")
                benefitChip("sparkles", "AI recipes")
                benefitChip("camera", "Bag scan")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if SupabaseService.isConfigured {
                appleButton
                HStack(spacing: 12) {
                    Rectangle().fill(StudioTheme.line).frame(height: 1)
                    Text("or continue with email").font(.caption).foregroundStyle(StudioTheme.muted).fixedSize()
                    Rectangle().fill(StudioTheme.line).frame(height: 1)
                }
                accountMode
                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(messageIsError ? StudioTheme.warning : StudioTheme.mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("account.message")
                        .accessibilityFocused($messageFocused)
                }
                VStack(alignment: .leading, spacing: 16) {
                    emailInput
                    passwordInput
                    if createsAccount { confirmationInput }
                }
                .disabled(isAuthenticating)
                Button { Task { await authenticate() } } label: {
                    HStack(spacing: 10) {
                        if isAuthenticating { ProgressView().tint(StudioTheme.background) }
                        Text(isAuthenticating ? "Connecting…" : createsAccount ? "Create account" : "Log in")
                        if !isAuthenticating { Image(systemName: "arrow.right").accessibilityHidden(true) }
                    }
                }
                .buttonStyle(WelcomePrimaryButton())
                .disabled(isAuthenticating)
                .accessibilityIdentifier("account.submit")

                Text(createsAccount
                    ? "Your on-device recipes come with you. We’ll email a link to confirm your account."
                    : "Logging in restores your cloud recipes and replaces this iPhone’s recipe list. Export your library first to keep a separate copy.")
                    .font(.footnote).foregroundStyle(StudioTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("This build supports local brewing and recipes. Accounts and AI aren’t configured yet.", systemImage: "icloud.slash")
                    .font(.subheadline).foregroundStyle(StudioTheme.muted).studioCard()
            }

            DisclosureGroup {
                AccountBenefitsView().padding(.top, 12)
            } label: {
                Text("What changes when I sign in?")
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
            .tint(StudioTheme.muted)
            .accessibilityIdentifier("account.benefits")
        }
        .onChange(of: focusedField) { old, _ in
            if let old { visitedFields.insert(old) }
        }
        .onChange(of: createsAccount) { _, _ in
            focusedField = nil
            password = ""
            confirmation = ""
            revealsPassword = false
            attemptedSubmission = false
            visitedFields = []
            message = nil
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    private var appleButton: some View {
        #if XBLOOM_PERSONAL_TEAM && !targetEnvironment(simulator)
        Text("Apple sign-in is unavailable in this development build. Use email or continue without an account.")
            .font(.footnote)
            .foregroundStyle(StudioTheme.muted)
            .accessibilityIdentifier("account.apple.unavailable")
        #else
        SignInWithAppleButton(.continue) { request in
            let value = UUID().uuidString + UUID().uuidString
            nonce = value
            message = nil
            isAuthenticating = true
            focusedField = nil
            request.requestedScopes = [.email]
            request.nonce = SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }.joined()
        } onCompletion: { result in
            completeAppleSignIn(result)
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .disabled(isAuthenticating)
        .accessibilityIdentifier("account.apple")
        #endif
    }

    private var accountMode: some View {
        HStack(spacing: 4) {
            modeButton("Log in", creates: false)
            modeButton("Create account", creates: true)
        }
        .padding(4)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .disabled(isAuthenticating)
    }

    private func modeButton(_ title: String, creates: Bool) -> some View {
        Button {
            createsAccount = creates
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(createsAccount == creates ? .primary : StudioTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(createsAccount == creates ? StudioTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: createsAccount)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(createsAccount == creates ? .isSelected : [])
        .accessibilityIdentifier(creates ? "account.mode.create" : "account.mode.login")
    }

    private var emailInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Email address")
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focusedField, equals: .email).submitLabel(.next)
                .onSubmit { focusedField = .password }
                .accessibilityLabel("Email address").accessibilityIdentifier("account.email")
                .padding(.horizontal, 16).frame(minHeight: 52)
                .background(fieldBackground(.email))
            fieldError(.email)
        }
    }

    private var passwordInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("Password")
                Spacer()
                if createsAccount { Text("8+ characters").font(.caption).foregroundStyle(StudioTheme.muted) }
            }
            HStack(spacing: 0) {
                Group {
                    if revealsPassword { TextField("Enter your password", text: $password) }
                    else { SecureField("Enter your password", text: $password) }
                }
                .textContentType(createsAccount ? .newPassword : .password)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focusedField, equals: .password)
                .submitLabel(createsAccount ? .next : .go)
                .onSubmit {
                    if createsAccount { focusedField = .confirmation }
                    else { Task { await authenticate() } }
                }
                .accessibilityLabel("Password").accessibilityIdentifier("account.password")
                Button { revealsPassword.toggle() } label: {
                    Image(systemName: revealsPassword ? "eye.slash" : "eye")
                        .foregroundStyle(StudioTheme.muted).frame(width: 44, height: 52)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealsPassword ? "Hide password" : "Show password")
            }
            .padding(.leading, 16).padding(.trailing, 4)
            .background(fieldBackground(.password))
            fieldError(.password)
        }
    }

    private var confirmationInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Confirm password")
            SecureField("Enter it once more", text: $confirmation)
                .textContentType(.newPassword).focused($focusedField, equals: .confirmation)
                .submitLabel(.go).onSubmit { Task { await authenticate() } }
                .accessibilityLabel("Confirm password").accessibilityIdentifier("account.confirmation")
                .padding(.horizontal, 16).frame(minHeight: 52)
                .background(fieldBackground(.confirmation))
            fieldError(.confirmation)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.medium)).accessibilityHidden(true)
    }

    private func fieldBackground(_ field: Field) -> some View {
        RoundedRectangle(cornerRadius: 12).fill(StudioTheme.panel)
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    visibleError(field) != nil ? StudioTheme.warning : focusedField == field ? StudioTheme.accent : StudioTheme.muted.opacity(0.55),
                    lineWidth: focusedField == field ? 1.5 : 1
                )
            }
    }

    @ViewBuilder private func fieldError(_ field: Field) -> some View {
        if let error = visibleError(field) {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.footnote).foregroundStyle(StudioTheme.warning)
                .accessibilityIdentifier("account.error.\(field)")
        }
    }

    private func visibleError(_ field: Field) -> String? {
        attemptedSubmission || visitedFields.contains(field) ? validationError(field) : nil
    }

    private func validationError(_ field: Field) -> String? {
        switch field {
        case .email:
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(where: \.isWhitespace)
                ? nil : "Enter a valid email address."
        case .password:
            if password.isEmpty { return "Enter your password." }
            return createsAccount && password.count < 8 ? "Use at least 8 characters." : nil
        case .confirmation:
            return createsAccount && password != confirmation ? "Your passwords don’t match." : nil
        }
    }

    private func benefitChip(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon).font(.caption).foregroundStyle(StudioTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func authenticate() async {
        guard !isAuthenticating else { return }
        attemptedSubmission = true
        let fields: [Field] = createsAccount ? [.email, .password, .confirmation] : [.email, .password]
        if let invalid = fields.first(where: { validationError($0) != nil }) {
            focusedField = invalid
            return
        }
        focusedField = nil
        isAuthenticating = true
        message = nil
        defer { isAuthenticating = false }
        do {
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if createsAccount { try await cloud.signUp(email: address, password: password) }
            else { try await cloud.signIn(email: address, password: password) }
            password = ""
            confirmation = ""
            attemptedSubmission = false
            visitedFields = []
            messageIsError = false
            message = cloud.statusMessage
            messageFocused = true
        } catch {
            messageIsError = true
            message = error.localizedDescription
            messageFocused = true
        }
    }
    private func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        guard let requestNonce = nonce else {
            isAuthenticating = false
            messageIsError = true
            message = "Please try Sign in with Apple again."
            messageFocused = true
            return
        }
        nonce = nil
        switch result {
        case .failure(let error):
            isAuthenticating = false
            if (error as? ASAuthorizationError)?.code != .canceled {
                messageIsError = true
                message = error.localizedDescription
                messageFocused = true
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8) else {
                isAuthenticating = false
                messageIsError = true
                message = "Apple didn’t return a sign-in token. Please try again."
                messageFocused = true
                return
            }
            Task { @MainActor in
                defer { isAuthenticating = false }
                do {
                    try await cloud.signInWithApple(idToken: token, nonce: requestNonce)
                } catch {
                    messageIsError = true
                    message = error.localizedDescription
                    messageFocused = true
                }
            }
        }
    }
}

struct AccountBenefitsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            benefit("Without an account", icon: "iphone", detail:
                "Brew, edit and share recipes, track beans and history, and use every Bluetooth tool. Your library stays on this iPhone.")
            Rectangle().fill(StudioTheme.line).frame(height: 1)
            benefit("With an account", icon: "icloud", detail:
                "Add cloud sync and restore, scan coffee bags, create AI recipes, and improve them using cup feedback. Internet required.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private func benefit(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(StudioTheme.accent)
                .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(StudioTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
