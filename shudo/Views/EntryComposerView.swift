import SwiftUI
import PhotosUI
import UIKit

struct EntryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = AudioRecorder()
    @State private var text: String = ""
    @State private var pickedImage: PhotosPickerItem?
    @State private var uiImage: UIImage?
    @State private var isSubmitting = false

    let onSubmit: (String?, Data?, UIImage?) async -> Void

    private var canSubmit: Bool {
        !isSubmitting && (uiImage != nil || !text.isEmpty || audio.recordedFileURL != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Notes") {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                }

                Section("Image") {
                    PhotosPicker("Choose Photo", selection: $pickedImage, matching: .images)
                    if let img = uiImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.l))
                            .overlay(RoundedRectangle(cornerRadius: Design.Radius.l).stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline))
                    }
                }

                Section("Voice") {
                    HStack {
                        Button(action: toggleRecord) {
                            Label(audio.isRecording ? "Stop" : "Record", systemImage: audio.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .tint(Design.Color.accentPrimary)
                        .foregroundStyle(audio.isRecording ? Design.Color.danger : Design.Color.accentPrimary)
                        .disabled(isSubmitting)
                        Spacer()
                        if let url = audio.recordedFileURL {
                            Text(url.lastPathComponent)
                                .font(.footnote)
                                .foregroundStyle(Design.Color.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("New Entry")
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
                            HStack(spacing: 6) { Image(systemName: "paperplane.fill"); Text("Submit") }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
        .onChange(of: pickedImage) { _, newValue in
            Task { @MainActor in
                guard let item = newValue else { return }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    uiImage = img
                }
            }
        }
    }

    private func toggleRecord() {
        if audio.isRecording { audio.stopRecording() } else { audio.startRecording() }
    }

    private func submit() {
        // Capture all data BEFORE any async work to prevent race conditions
        let t = text.isEmpty ? nil : text
        let img = uiImage
        // Read audio file into Data immediately to prevent temp file cleanup race
        let audioData: Data? = audio.recordedFileURL.flatMap { try? Data(contentsOf: $0) }
        
        isSubmitting = true
        Task {
            await onSubmit(t, audioData, img)
            await MainActor.run {
                isSubmitting = false
                dismiss()
            }
        }
    }
}


