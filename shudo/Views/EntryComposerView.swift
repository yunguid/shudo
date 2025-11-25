import SwiftUI
import PhotosUI
import UIKit

struct EntryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var pickedImage: PhotosPickerItem?
    @State private var uiImage: UIImage?
    @State private var isSubmitting = false

    let onSubmit: (String?, UIImage?) async -> Void

    private var canSubmit: Bool {
        !isSubmitting && (uiImage != nil || !text.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Photo section - primary
                    VStack(alignment: .leading, spacing: 10) {
                        Label("PHOTO", systemImage: "camera.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .tracking(0.5)
                        
                        if let img = uiImage {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.l))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Design.Radius.l)
                                            .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                                    )
                                
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        uiImage = nil
                                        pickedImage = nil
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(.black.opacity(0.6), in: Circle())
                                }
                                .padding(10)
                            }
                        } else {
                            PhotosPicker(selection: $pickedImage, matching: .images) {
                                VStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(Design.Color.accentPrimary.opacity(0.1))
                                            .frame(width: 56, height: 56)
                                        Image(systemName: "camera.fill")
                                            .font(.title3)
                                            .foregroundStyle(Design.Color.accentPrimary)
                                    }
                                    Text("Add a photo of your meal")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Design.Color.ink)
                                    Text("or describe it below")
                                        .font(.caption)
                                        .foregroundStyle(Design.Color.muted)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 160)
                                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.l))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Design.Radius.l)
                                        .strokeBorder(
                                            Design.Color.accentPrimary.opacity(0.3),
                                            style: StrokeStyle(lineWidth: 1.5, dash: [8])
                                        )
                                )
                            }
                        }
                    }
                    
                    // Text input
                    VStack(alignment: .leading, spacing: 10) {
                        Label("DESCRIPTION", systemImage: "text.alignleft")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .tracking(0.5)
                        
                        TextField("What did you eat?", text: $text, axis: .vertical)
                            .lineLimit(4...8)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .foregroundStyle(Design.Color.ink)
                            .padding(16)
                            .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.m)
                                    .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                            )
                    }
                    
                    // Hint
                    if uiImage == nil && text.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(Design.Color.warning)
                            Text("Add a photo or description to log your meal")
                                .font(.caption)
                                .foregroundStyle(Design.Color.muted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Design.Color.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Design.Radius.m))
                    }
                }
                .padding(20)
            }
            .navigationTitle("Log Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Design.Color.muted)
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Design.Color.accentPrimary)
                        } else {
                            Text("Submit")
                                .fontWeight(.semibold)
                                .foregroundStyle(canSubmit ? Design.Color.accentPrimary : Design.Color.subtle)
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .scrollContentBackground(.hidden)
            .background(Design.Color.paper)
        }
        .onChange(of: pickedImage) { _, newValue in
            Task { @MainActor in
                guard let item = newValue else { return }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    withAnimation(.easeInOut(duration: 0.2)) { uiImage = img }
                }
            }
        }
    }

    private func submit() {
        let t = text.isEmpty ? nil : text
        let img = uiImage
        
        isSubmitting = true
        Task {
            await onSubmit(t, img)
            await MainActor.run {
                isSubmitting = false
                dismiss()
            }
        }
    }
}
