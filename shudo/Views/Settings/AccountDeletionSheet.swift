import SwiftUI
import UIKit

/// Type DELETE, then the account and everything in it is erased.
struct AccountDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    let onDelete: () async throws -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Design.Space.xl) {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    Text("Delete your account?")
                        .font(Design.Typeface.display(.title2))
                        .foregroundStyle(Design.Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your meals, photos, bio and sign-in are erased for good.")
                        .font(Design.Typeface.text(.body))
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Written on a line, like signing for it.
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    TextField(
                        "",
                        text: $confirmation,
                        prompt: Text("Type “delete” to confirm").foregroundStyle(Design.Color.textTertiary)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Design.Typeface.text(.body, weight: .medium))
                    .foregroundStyle(Design.Color.textPrimary)
                    .tint(Design.Color.danger)
                    .focused($fieldFocused)
                    .disabled(isDeleting)
                    .accessibilityLabel("Type delete to confirm")
                    Rectangle()
                        .fill(canDelete ? Design.Color.danger.opacity(0.7) : Design.Color.strokeStrong)
                        .frame(height: 1)
                }
                .padding(.top, Design.Space.s)

                if let errorMessage {
                    Text(errorMessage)
                        .font(Design.Typeface.text(.footnote))
                        .foregroundStyle(Design.Color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(role: .destructive, action: deleteAccount) {
                    HStack(spacing: 8) {
                        if isDeleting {
                            ProgressView().controlSize(.small).tint(Design.Color.sumi)
                        }
                        Text(isDeleting ? "Deleting…" : "Delete account")
                    }
                    .font(Design.Typeface.text(.subheadline, weight: .semibold))
                    .foregroundStyle(isArmed ? Design.Color.sumi : Design.Color.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        isArmed ? Design.Color.danger : Design.Color.surface2,
                        in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canDelete)
            }
            .padding(.horizontal, Design.Space.xl)
            .padding(.top, Design.Space.s)
            .padding(.bottom, Design.Space.l)
            .settlesOnAppear()
            .background(Design.Color.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Design.Color.textPrimary)
                        .disabled(isDeleting)
                }
            }
            .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: isArmed)
            .interactiveDismissDisabled(isDeleting)
            .onAppear { fieldFocused = true }
        }
    }

    /// Sentence case on screen (no shouting): "delete" in any case arms it,
    /// still exactly the word, no spaces; the server gets the policy's own
    /// confirmation token either way.
    private var canDelete: Bool {
        !isDeleting && AccountDeletionPolicy.isConfirmed(confirmation.uppercased())
    }

    private var isArmed: Bool { canDelete || isDeleting }

    private func deleteAccount() {
        guard canDelete else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await onDelete()
            } catch {
                await MainActor.run {
                    isDeleting = false
                    errorMessage = error.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
}
