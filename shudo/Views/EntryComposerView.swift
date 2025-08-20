import SwiftUI
import PhotosUI
import UIKit

struct EntryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = AudioRecorder()
    @State private var text: String = ""
    @State private var pickedImage: PhotosPickerItem?
    @State private var uiImage: UIImage?

    let onSubmit: (String?, URL?, UIImage?) async -> Void

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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let t = text.isEmpty ? nil : text
                        let url = audio.recordedFileURL
                        let img = uiImage
                        dismiss()
                        Task { await onSubmit(t, url, img) }
                    } label: {
                        HStack(spacing: 6) { Image(systemName: "paperplane.fill"); Text("Submit") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(uiImage == nil && (text.isEmpty && audio.recordedFileURL == nil))
                }
            }
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
}


