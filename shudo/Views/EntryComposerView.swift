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
                VStack(spacing: 20) {
                    // Text input
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Notes", systemImage: "text.alignleft")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                        
                        TextField("What did you eat?", text: $text, axis: .vertical)
                            .lineLimit(4...8)
                            .textFieldStyle(.plain)
                            .padding(14)
                            .background(Design.Color.fill, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                            .overlay(
                                RoundedRectangle(cornerRadius: Design.Radius.m)
                                    .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                            )
                    }
                    
                    // Photo picker
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Photo", systemImage: "photo")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                        
                        if let img = uiImage {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.l))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Design.Radius.l)
                                            .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                                    )
                                
                                Button {
                                    withAnimation { 
                                        uiImage = nil
                                        pickedImage = nil
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .padding(8)
                            }
                        } else {
                            PhotosPicker(selection: $pickedImage, matching: .images) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                    Text("Add Photo")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(Design.Color.accentPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 100)
                                .background(Design.Color.fill, in: RoundedRectangle(cornerRadius: Design.Radius.l))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Design.Radius.l)
                                        .strokeBorder(Design.Color.accentPrimary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8]))
                                )
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Log Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Submit")
                                .fontWeight(.semibold)
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
                    withAnimation { uiImage = img }
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
