import SwiftUI

struct AuthView: View {
    private enum Field { case email, password }

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 30) {
                    Spacer(minLength: 62)

                    VStack(spacing: 13) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Design.Color.accentPrimary.opacity(0.30),
                                            Design.Color.accentSecondary.opacity(0.08)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 76, height: 76)

                            Image(systemName: "waveform.and.mic")
                                .font(.system(size: 27, weight: .medium))
                                .foregroundStyle(Design.Color.accentSecondary)
                        }

                        Text("Shudo")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Design.Color.ink)

                        Text("Your private meal log")
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.muted)
                    }

                    VStack(spacing: 0) {
                        credentialRow(systemImage: "envelope", label: "Email") {
                            TextField("you@example.com", text: $email)
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
                            SecureField("Password", text: $password)
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

                    Button(action: submitIfReady) {
                        HStack(spacing: 9) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(isLoading ? "Opening…" : "Open Shudo")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.48)

                    Spacer(minLength: 42)

                    Text("Your OpenAI key stays on the server. Captures are sent securely for private analysis and never posted publicly.")
                        .font(.caption)
                        .foregroundStyle(Design.Color.subtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var canSubmit: Bool {
        !isLoading && isEmailValid && !password.isEmpty
    }

    private var isEmailValid: Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = normalized.firstIndex(of: "@") else { return false }
        let domain = normalized[normalized.index(after: at)...]
        return normalized.count >= 5 && domain.contains(".")
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
                .foregroundStyle(Design.Color.ink)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 58)
    }

    private func submitIfReady() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await signIn() }
    }

    @MainActor
    private func signIn() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let normalizedEmail = email
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            try await AuthSessionManager.shared.signIn(
                email: normalizedEmail,
                password: password
            )
        } catch let friendly as SupabaseAuthService.FriendlyAuthError {
            errorMessage = friendly.friendlyMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
