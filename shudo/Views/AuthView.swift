import SwiftUI
import AuthenticationServices
import UIKit

@MainActor
private final class OAuthPresentationContext: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive })
        if let window = activeScene?.windows.first(where: \.isKeyWindow) ?? scenes.first?.windows.first {
            return window
        }
        // A scene always exists while auth UI is on screen.
        guard let scene = activeScene ?? scenes.first else {
            preconditionFailure("OAuth presented without a connected window scene")
        }
        return ASPresentationAnchor(windowScene: scene)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    wordmark
                        .padding(.top, Design.Space.xxxl)

                    VStack(alignment: .leading, spacing: Design.Space.l) {
                        underlinedField(.email) {
                            TextField(
                                "",
                                text: $email,
                                prompt: Text(verbatim: "Email")
                                    .foregroundStyle(Design.Color.textTertiary)
                            )
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .email)
                            .onSubmit { focusedField = .password }
                            .accessibilityLabel("Email")
                        }

                        underlinedField(.password) {
                            SecureField(
                                "",
                                text: $password,
                                prompt: Text("Password")
                                    .foregroundStyle(Design.Color.textTertiary)
                            )
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .onSubmit { submitIfReady() }
                            .accessibilityLabel("Password")
                        }

                        passwordFootnote
                    }
                    .padding(.top, Design.Space.section)

                    messages
                        .padding(.top, Design.Space.l)

                    VStack(alignment: .leading, spacing: Design.Space.m) {
                        Button(action: submitIfReady) {
                            HStack(spacing: 9) {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(Design.Color.onCream)
                                }
                                Text(isLoading
                                     ? (isCreatingAccount ? "Creating…" : "Opening…")
                                     : (isCreatingAccount ? "Create account" : "Sign in"))
                                    .contentTransition(.opacity)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSubmit)

                        Button(action: toggleMode) {
                            Text(isCreatingAccount ? "I have an account" : "Create an account")
                                .font(Design.Typeface.text(.subheadline, weight: .medium))
                                .foregroundStyle(Design.Color.textSecondary)
                                .contentTransition(.opacity)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                    .padding(.top, Design.Space.xl)

                    oauthProviderDiscoveryContent
                        .padding(.top, Design.Space.l)

                    Spacer(minLength: Design.Space.section)
                }
                .frame(maxWidth: 430, alignment: .leading)
                .padding(.horizontal, Design.Space.xl)
                .frame(maxWidth: .infinity)
                .settlesOnAppear()
            }
            .scrollDismissesKeyboard(.interactively)
            .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: focusedField)
            .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: errorMessage)
            .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: recoveryMessage)
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

    /// The pad mark, the name in serif, and one quiet line that slides
    /// like a shoji panel when the mode changes.
    private var wordmark: some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            CoachAvatar(size: 48)
            VStack(alignment: .leading, spacing: Design.Space.s) {
                Text("Shudo")
                    .font(Design.Typeface.display(.largeTitle))
                    .foregroundStyle(Design.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ZStack(alignment: .leading) {
                    if isCreatingAccount {
                        modeLine("Create your account.")
                            .transition(.shoji(.trailing, reduceMotion: reduceMotion))
                    } else {
                        modeLine("Sign in to continue.")
                            .transition(.shoji(.leading, reduceMotion: reduceMotion))
                    }
                }
            }
        }
    }

    private func modeLine(_ text: String) -> some View {
        Text(text)
            .font(Design.Typeface.text(.body))
            .foregroundStyle(Design.Color.textSecondary)
    }

    /// Under the password: "Forgot password?" when signing in, the length
    /// rule when creating an account. Same slot, sliding past each other.
    private var passwordFootnote: some View {
        ZStack(alignment: .leading) {
            if isCreatingAccount {
                Text("At least 10 characters.")
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(password.count >= 10 ? Design.Color.textSecondary : Design.Color.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .transition(.shoji(.trailing, reduceMotion: reduceMotion))
            } else {
                Button(action: requestPasswordRecovery) {
                    HStack(spacing: 7) {
                        if isRecoveryLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Design.Color.textSecondary)
                        }
                        Text(isRecoveryLoading ? "Sending…" : "Forgot password?")
                    }
                    .font(Design.Typeface.text(.footnote, weight: .medium))
                    .foregroundStyle(Design.Color.textSecondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityHint("Sends a password reset link to the email above")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.shoji(.leading, reduceMotion: reduceMotion))
            }
        }
        .padding(.top, -Design.Space.s)
    }

    /// Errors in crimson, confirmations in oak; each arrives like ink.
    @ViewBuilder
    private var messages: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            if let errorMessage {
                Text(errorMessage)
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(Design.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.ink(reduceMotion: reduceMotion))
            }

            if let recoveryMessage {
                Text(recoveryMessage)
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.ink(reduceMotion: reduceMotion))
            }

            if canResendConfirmation {
                Button {
                    resendConfirmation()
                } label: {
                    HStack(spacing: 7) {
                        if isConfirmationLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Design.Color.textSecondary)
                        }
                        Text(isConfirmationLoading
                             ? "Sending confirmation…"
                             : "Resend confirmation email")
                    }
                    .font(Design.Typeface.text(.footnote, weight: .medium))
                    .foregroundStyle(Design.Color.oak)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityHint("Sends a new account confirmation link to the email above")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleMode() {
        withAnimation(Design.Motion.calm(Design.Motion.shoji, reduceMotion: reduceMotion)) {
            isCreatingAccount.toggle()
            errorMessage = nil
            recoveryMessage = nil
            canResendConfirmation = false
        }
    }

    /// A field written on a line, like a form on washi: no box, no icon,
    /// the rule warming to Pernambuco while you write.
    private func underlinedField<Content: View>(
        _ field: Field,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isFocused = focusedField == field
        return VStack(alignment: .leading, spacing: 0) {
            content()
                .font(Design.Typeface.text(.body))
                .foregroundStyle(Design.Color.textPrimary)
                .tint(Design.Color.pernambuco)
                .frame(minHeight: 52)
            Rectangle()
                .fill(isFocused ? Design.Color.pernambuco.opacity(0.75) : Design.Color.strokeStrong)
                .frame(height: isFocused ? 1 : Design.Stroke.hairline)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
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
                .font(Design.Typeface.text(.subheadline, weight: .medium))
                .foregroundStyle(Design.Color.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    Design.Color.surface1,
                    in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
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
            // Quiet until the providers arrive; holds the row's height.
            Color.clear
                .frame(height: 48)
                .accessibilityHidden(true)
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
            Button("Apple and Google sign-in didn’t load · Retry") {
                Task { await loadOAuthProviders() }
            }
            .font(Design.Typeface.text(.footnote))
            .foregroundStyle(Design.Color.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityIdentifier("oauth-provider-discovery-retry")
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
            recoveryMessage = "If that email has an account, a reset link is on its way."
        } catch {
            errorMessage = "We couldn’t send a reset link right now. Please try again."
        }
    }
}
