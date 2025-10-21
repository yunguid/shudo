import SwiftUI
import AuthenticationServices
import CryptoKit

struct AuthView: View {
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentNonce: String?
    @State private var confirmationSent: Bool = false
    @ObservedObject private var session = AuthSessionManager.shared
    private enum CurrentAction { case signIn, signUp }
    @State private var currentAction: CurrentAction? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: Design.Spacing.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("shudo").font(.largeTitle.weight(.bold)).foregroundStyle(Design.Color.ink)
                    Text("Sign in to continue").foregroundStyle(Design.Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: Design.Spacing.m) {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .fieldStyle()

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .fieldStyle()
                }

                if let e = error {
                    Text(e).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if confirmationSent == false {
                    HStack {
                        Button(currentAction == .signIn ? "Signing In…" : "Sign In") { Task { await signIn() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading || !isEmailValid || password.isEmpty)

                        Button(currentAction == .signUp ? "Signing Up…" : "Sign Up") { Task { await signUp() } }
                            .buttonStyle(.bordered)
                            .disabled(isLoading || !isEmailValid || password.isEmpty || session.session != nil)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if session.session != nil {
                            Text("You're already signed in.")
                                .font(.caption)
                                .foregroundStyle(Design.Color.muted)
                                .padding(.top, 6)
                        }
                    }
                    HStack(spacing: 16) {
                        Button("Forgot password?") { Task { await forgotPassword() } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Design.Color.accentPrimary)
                            .buttonStyle(.plain)
                            .disabled(isLoading || !isEmailValid)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } else {
                    VStack(spacing: 8) {
                        Text("Check your email to confirm your account.")
                            .font(.callout)
                            .foregroundStyle(Design.Color.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            Button("Resend Email") { Task { await resendConfirmation() } }
                                .buttonStyle(.bordered)
                                .disabled(isLoading || !isEmailValid)
                            Button("Back") { confirmationSent = false }
                                .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                SignInWithAppleButton(.signIn) { request in
                    let nonce = randomNonceString()
                    currentNonce = nonce
                    request.requestedScopes = [.email]
                    request.nonce = sha256(nonce)
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                              let tokenData = credential.identityToken,
                              let token = String(data: tokenData, encoding: .utf8) else {
                            self.error = "No Apple token"
                            return
                        }
                        Task { await signInWithApple(idToken: token, nonce: currentNonce) }
                    case .failure(let err):
                        self.error = err.localizedDescription
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous))

                Spacer(minLength: 0)
            }
            .padding(20)
            .onChange(of: email) { _ in
                if confirmationSent { confirmationSent = false; error = nil }
                if currentAction != nil { currentAction = nil }
            }
        }
    }

    private var isEmailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = e.firstIndex(of: "@") else { return false }
        let domain = e[e.index(after: at)...]
        return e.count >= 5 && domain.contains(".")
    }

    private func signIn() async {
        currentAction = .signIn
        await authCall {
            let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            try await AuthSessionManager.shared.signIn(email: e, password: password)
        }
        currentAction = nil
    }
    private func signUp() async {
        currentAction = .signUp
        isLoading = true; error = nil
        do {
            let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let result = try await AuthSessionManager.shared.signUp(email: e, password: password)
            switch result {
            case .confirmationSent:
                confirmationSent = true
            case .didSignIn:
                // Session is set by AuthSessionManager when didSignIn.
                break
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
        currentAction = nil
    }
    private func authCall(_ block: () async throws -> Void) async {
        isLoading = true; error = nil
        do {
            try await block()
        } catch {
            if let fe = error as? SupabaseAuthService.FriendlyAuthError {
                let code = fe.supabaseErrorCode?.lowercased() ?? ""
                let msg = fe.serverMessage?.lowercased() ?? ""
                if code.contains("email_not_confirmed") || msg.contains("email not confirmed") {
                    // Guide user into resend-confirmation UI
                    confirmationSent = true
                    self.error = nil
                } else {
                    self.error = fe.friendlyMessage
                }
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        isLoading = false
    }

    private func signInWithApple(idToken: String, nonce: String?) async {
        isLoading = true; error = nil
        do {
            let s = try await SupabaseAuthService().signInWithApple(idToken: idToken, nonce: nonce)
            await MainActor.run { AuthSessionManager.shared.setSession(s) }
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }

    private func resendConfirmation() async {
        await authCall {
            let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            try await SupabaseAuthService().resendSignUpConfirmation(email: e)
        }
    }

    private func forgotPassword() async {
        await authCall {
            let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            try await SupabaseAuthService().sendPasswordReset(email: e)
        }
    }

    // MARK: - Nonce/Hash
    private func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count { result.append(charset[Int(random)]) ; remainingLength -= 1 }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}


