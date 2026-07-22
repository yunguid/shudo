import SwiftUI
import AuthenticationServices
import UIKit

@MainActor
private final class OAuthPresentationContext: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}

enum AuthEmailInput {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ value: String) -> Bool {
        let candidate = normalized(value)
        guard !candidate.contains(where: \.isWhitespace) else { return false }

        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }

        let localPart = parts[0]
        let domain = parts[1]
        return !localPart.isEmpty
            && domain.contains(".")
            && !domain.hasPrefix(".")
            && !domain.hasSuffix(".")
    }
}

enum OAuthProviderDiscoveryState: Equatable {
    case loading
    case loaded([SupabaseAuthService.OAuthProvider])
    case failed
}

struct AuthView: View {
    private enum Field { case email, password }

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var isRecoveryLoading = false
    @State private var isConfirmationLoading = false
    @State private var isCreatingAccount = false
    @State private var isOAuthLoading = false
    @State private var oauthProviderDiscovery: OAuthProviderDiscoveryState = .loading
    @State private var oauthSession: ASWebAuthenticationSession?
    @State private var pendingOAuthVerifier: String?
    @State private var oauthPresentationContext = OAuthPresentationContext()
    @State private var errorMessage: String?
    @State private var recoveryMessage: String?
    @State private var canResendConfirmation = false
    @ObservedObject private var router = AppRouter.shared
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 30) {
                    Spacer(minLength: 62)

                    Text("Shudo")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Design.Color.ink)

                    VStack(spacing: 12) {
                        VStack(spacing: 0) {
                            credentialRow(systemImage: "envelope", label: "Email") {
                                TextField(
                                    "",
                                    text: $email,
                                    prompt: Text(verbatim: "you@example.com")
                                        .foregroundStyle(Design.Color.muted)
                                )
                                .foregroundStyle(Design.Color.ink)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .focused($focusedField, equals: .email)
                                .onSubmit { focusedField = .password }
                            }

                            Rectangle()
                                .fill(Design.Color.rule)
                                .frame(height: 0.5)
                                .padding(.leading, 48)

                            credentialRow(systemImage: "lock", label: "Password") {
                                SecureField(
                                    "",
                                    text: $password,
                                    prompt: Text("Password")
                                        .foregroundStyle(Design.Color.muted)
                                )
                                .foregroundStyle(Design.Color.ink)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focusedField, equals: .password)
                                .onSubmit { submitIfReady() }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(
                            Design.Color.elevated,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )

                        if !isCreatingAccount {
                            Button(action: requestPasswordRecovery) {
                            HStack(spacing: 7) {
                                if isRecoveryLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(Design.Color.accentSecondary)
                                }
                                Text(isRecoveryLoading ? "Sending reset link…" : "Forgot password?")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Design.Color.accentSecondary)
                            .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .accessibilityHint("Sends a password reset link to the email above")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }

                    if let errorMessage {
                        HStack(spacing: 9) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(errorMessage)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.footnote)
                        .foregroundStyle(Design.Color.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }

                    if let recoveryMessage {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityHidden(true)
                            Text(recoveryMessage)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.footnote)
                        .foregroundStyle(Design.Color.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .combine)
                    }

                    if canResendConfirmation {
                        Button {
                            resendConfirmation()
                        } label: {
                            HStack(spacing: 7) {
                                if isConfirmationLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(Design.Color.accentSecondary)
                                }
                                Text(isConfirmationLoading
                                     ? "Sending confirmation…"
                                     : "Resend confirmation email")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Design.Color.accentSecondary)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityHint("Sends a new account confirmation link to the email above")
                    }

                    Button(action: submitIfReady) {
                        HStack(spacing: 9) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(isLoading
                                 ? (isCreatingAccount ? "Creating…" : "Opening…")
                                 : (isCreatingAccount ? "Create account" : "Open Shudo"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.48)

                    Button {
                        isCreatingAccount.toggle()
                        errorMessage = nil
                        recoveryMessage = nil
                        canResendConfirmation = false
                    } label: {
                        Text(isCreatingAccount
                             ? "Already have an account? Sign in"
                             : "New to Shudo? Create account")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Design.Color.accentSecondary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    oauthProviderDiscoveryContent

                    Spacer(minLength: 42)
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: email) {
                recoveryMessage = nil
                canResendConfirmation = false
            }
            .onChange(of: router.authCallbackURL) { _, callbackURL in
                guard let callbackURL, let verifier = pendingOAuthVerifier else { return }
                router.consumeAuthCallback(callbackURL)
                Task { await finishOAuth(callbackURL: callbackURL, verifier: verifier) }
            }
            .task {
                await loadOAuthProviders()
            }
        }
    }

    private var isBusy: Bool {
        isLoading || isRecoveryLoading || isConfirmationLoading || isOAuthLoading
    }

    private var canSubmit: Bool {
        !isBusy && isEmailValid
            && password.count >= (isCreatingAccount ? 10 : 1)
    }

    private var isEmailValid: Bool {
        AuthEmailInput.isValid(email)
    }

    private func credentialRow<Content: View>(
        systemImage: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Design.Color.muted)
                .frame(width: 20)

            content()
                .font(.body)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 58)
    }

    private func submitIfReady() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await submitCredentials() }
    }

    private func socialButton(
        _ title: String,
        systemImage: String,
        provider: SupabaseAuthService.OAuthProvider
    ) -> some View {
        Button {
            startOAuth(provider)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    Design.Color.elevated,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("oauth-\(provider.rawValue)-button")
    }

    @ViewBuilder
    private var oauthProviderDiscoveryContent: some View {
        switch oauthProviderDiscovery {
        case .loading:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Design.Color.accentSecondary)
                Text("Checking sign-in options…")
            }
            .font(.footnote)
            .foregroundStyle(Design.Color.muted)
            .frame(maxWidth: .infinity, minHeight: 48)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("oauth-provider-discovery-loading")
        case .loaded(let providers):
            if !providers.isEmpty {
                HStack(spacing: 10) {
                    ForEach(providers, id: \.rawValue) { provider in
                        socialButton(
                            provider == .apple ? "Apple" : "Google",
                            systemImage: provider == .apple ? "apple.logo" : "g.circle.fill",
                            provider: provider
                        )
                    }
                }
            }
        case .failed:
            HStack(spacing: 10) {
                Label("Social sign-in couldn’t load.", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Retry") {
                    Task { await loadOAuthProviders() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.accentSecondary)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("oauth-provider-discovery-retry")
            }
            .padding(.horizontal, 14)
            .background(
                Design.Color.elevated,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .accessibilityIdentifier("oauth-provider-discovery-error")
        }
    }

    @MainActor
    private func loadOAuthProviders() async {
        oauthProviderDiscovery = .loading
        do {
            let providers = try await SupabaseAuthService().fetchEnabledOAuthProviders()
            oauthProviderDiscovery = .loaded(providers)
        } catch is CancellationError {
            return
        } catch {
            oauthProviderDiscovery = .failed
        }
    }

    private func requestPasswordRecovery() {
        guard !isLoading, !isRecoveryLoading else { return }
        guard isEmailValid else {
            recoveryMessage = nil
            errorMessage = "Enter a valid email address first."
            focusedField = .email
            return
        }

        focusedField = nil
        Task { await sendPasswordRecovery() }
    }

    @MainActor
    private func submitCredentials() async {
        isLoading = true
        errorMessage = nil
        recoveryMessage = nil
        defer { isLoading = false }

        do {
            let normalizedEmail = AuthEmailInput.normalized(email)
            if isCreatingAccount {
                let outcome = try await AuthSessionManager.shared.signUp(
                    email: normalizedEmail,
                    password: password
                )
                if case .confirmationRequired = outcome {
                    recoveryMessage = "Check your email to confirm your account, then sign in."
                    canResendConfirmation = true
                    isCreatingAccount = false
                    password = ""
                }
            } else {
                try await AuthSessionManager.shared.signIn(
                    email: normalizedEmail,
                    password: password
                )
            }
        } catch let friendly as SupabaseAuthService.FriendlyAuthError {
            errorMessage = friendly.friendlyMessage
            canResendConfirmation = SupabaseAuthService.isEmailNotConfirmed(friendly)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resendConfirmation() {
        guard !isBusy, isEmailValid else { return }
        focusedField = nil
        isConfirmationLoading = true
        errorMessage = nil
        recoveryMessage = nil
        Task {
            do {
                try await SupabaseAuthService().resendSignUpConfirmation(
                    email: AuthEmailInput.normalized(email)
                )
                await MainActor.run {
                    isConfirmationLoading = false
                    recoveryMessage = "Confirmation email sent. Open the new link, then sign in."
                }
            } catch {
                await MainActor.run {
                    isConfirmationLoading = false
                    errorMessage = "Couldn’t send a confirmation email. Try again shortly."
                }
            }
        }
    }

    @MainActor
    private func startOAuth(_ provider: SupabaseAuthService.OAuthProvider) {
        errorMessage = nil
        recoveryMessage = nil
        do {
            let flow = try SupabaseAuthService().makeOAuthFlow(provider: provider)
            pendingOAuthVerifier = flow.codeVerifier
            isOAuthLoading = true
            let session = ASWebAuthenticationSession(
                url: flow.authorizationURL,
                callbackURLScheme: SupabaseAuthService.oauthCallbackURL.scheme
            ) { callbackURL, error in
                Task { @MainActor in
                    if let callbackURL {
                        await finishOAuth(
                            callbackURL: callbackURL,
                            verifier: flow.codeVerifier
                        )
                    } else {
                        pendingOAuthVerifier = nil
                        oauthSession = nil
                        isOAuthLoading = false
                        if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                            errorMessage = "Couldn’t finish social sign-in. Please try again."
                        }
                    }
                }
            }
            session.presentationContextProvider = oauthPresentationContext
            session.prefersEphemeralWebBrowserSession = true
            oauthSession = session
            if !session.start() {
                throw NSError(
                    domain: "Auth",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn’t open social sign-in"]
                )
            }
        } catch {
            pendingOAuthVerifier = nil
            oauthSession = nil
            isOAuthLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finishOAuth(callbackURL: URL, verifier: String) async {
        guard pendingOAuthVerifier == verifier else { return }
        defer {
            pendingOAuthVerifier = nil
            oauthSession = nil
            isOAuthLoading = false
        }
        do {
            try await AuthSessionManager.shared.completeOAuth(
                callbackURL: callbackURL,
                codeVerifier: verifier
            )
        } catch let friendly as SupabaseAuthService.FriendlyAuthError {
            errorMessage = friendly.friendlyMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func sendPasswordRecovery() async {
        isRecoveryLoading = true
        errorMessage = nil
        recoveryMessage = nil
        defer { isRecoveryLoading = false }

        do {
            try await SupabaseAuthService().requestPasswordRecovery(
                email: AuthEmailInput.normalized(email)
            )
            recoveryMessage = "If an account exists for this email, you’ll receive a reset link shortly."
        } catch {
            errorMessage = "We couldn’t send a reset link right now. Please try again."
        }
    }
}
