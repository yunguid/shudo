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
            VStack(spacing: 32) {
                // Logo & Title
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Design.Color.accentPrimary.opacity(0.2), Design.Color.accentPrimary.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                        Image(systemName: "fork.knife")
                            .font(.title)
                            .foregroundStyle(Design.Color.accentPrimary)
                    }
                    
                    Text("shudo")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Design.Color.ink)
                    Text("Track your nutrition with AI")
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.muted)
                }
                .padding(.top, 40)

                // Form
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                        TextField("you@example.com", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .font(.body)
                            .foregroundStyle(Design.Color.ink)
                            .padding(14)
                            .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.m)
                                    .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                        SecureField("••••••••", text: $password)
                            .textContentType(.password)
                            .font(.body)
                            .foregroundStyle(Design.Color.ink)
                            .padding(14)
                            .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.m)
                                    .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                            )
                    }
                }

                if let e = error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Design.Color.danger)
                        Text(e)
                            .font(.caption)
                            .foregroundStyle(Design.Color.danger)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Design.Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.m))
                }

                if confirmationSent == false {
                    VStack(spacing: 12) {
                        Button {
                            Task { await signIn() }
                        } label: {
                            HStack {
                                if currentAction == .signIn {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                                Text(currentAction == .signIn ? "Signing In…" : "Sign In")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isLoading || !isEmailValid || password.isEmpty)

                        Button {
                            Task { await signUp() }
                        } label: {
                            Text(currentAction == .signUp ? "Creating Account…" : "Create Account")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isLoading || !isEmailValid || password.isEmpty || session.session != nil)
                    }
                    
                    Button("Forgot password?") { Task { await forgotPassword() } }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.accentPrimary)
                        .disabled(isLoading || !isEmailValid)
                } else {
                    VStack(spacing: 16) {
                        VStack(spacing: 8) {
                            Image(systemName: "envelope.badge.fill")
                                .font(.title)
                                .foregroundStyle(Design.Color.success)
                            Text("Check your email")
                                .font(.headline)
                                .foregroundStyle(Design.Color.ink)
                            Text("We sent a confirmation link to verify your account.")
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.muted)
                                .multilineTextAlignment(.center)
                        }
                        
                        HStack(spacing: 12) {
                            Button("Resend") { Task { await resendConfirmation() } }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(isLoading || !isEmailValid)
                            Button("Back") { confirmationSent = false }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Design.Color.muted)
                        }
                    }
                    .padding(20)
                    .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.l))
                }

                Spacer()

                // Apple Sign In
                VStack(spacing: 12) {
                    HStack {
                        Rectangle()
                            .fill(Design.Color.rule)
                            .frame(height: 1)
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(Design.Color.subtle)
                        Rectangle()
                            .fill(Design.Color.rule)
                            .frame(height: 1)
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
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.m))
                }
            }
            .padding(24)
            .background(Design.Color.paper)
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
