import SwiftUI
import UIKit

/// Type DELETE, then the account and everything in it is erased.
struct AccountDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    let onDelete: () async throws -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete your account?")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Design.Color.textPrimary)
                    Text("Your meals, photos, bio and sign-in are erased for good.")
                        .font(.body)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Type DELETE to confirm", text: $confirmation)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .focused($fieldFocused)
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(
                        Design.Color.surface1,
                        in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    )
                    .disabled(isDeleting)
                    .accessibilityLabel("Type DELETE to confirm")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(role: .destructive, action: deleteAccount) {
                    HStack(spacing: 8) {
                        if isDeleting { ProgressView().tint(Design.Color.onEmber) }
                        Text(isDeleting ? "Deleting…" : "Delete account")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(canDelete || isDeleting ? Design.Color.onEmber : Design.Color.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        canDelete || isDeleting ? Design.Color.danger : Design.Color.surface2,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canDelete)
            }
            .padding(20)
            .background(Design.Color.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
            .onAppear { fieldFocused = true }
        }
    }

    private var canDelete: Bool {
        !isDeleting && AccountDeletionPolicy.isConfirmed(confirmation)
    }

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
