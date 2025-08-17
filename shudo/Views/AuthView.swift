import SwiftUI
import AuthenticationServices
import CryptoKit

struct AuthView: View {
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentNonce: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: Design.Spacing.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("shudo").font(.largeTitle.weight(.bold))
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

                HStack {
                    Button("Sign In") { Task { await signIn() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || email.isEmpty || password.isEmpty)

                    Button("Sign Up") { Task { await signUp() } }
                        .buttonStyle(.bordered)
                        .disabled(isLoading || email.isEmpty || password.isEmpty)
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
        }
    }

    private func signIn() async {
        await authCall { try await AuthSessionManager.shared.signIn(email: email, password: password) }
    }
    private func signUp() async {
        await authCall { try await AuthSessionManager.shared.signUp(email: email, password: password) }
    }
    private func authCall(_ block: () async throws -> Void) async {
        isLoading = true; error = nil
        do { try await block() } catch { self.error = error.localizedDescription }
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


