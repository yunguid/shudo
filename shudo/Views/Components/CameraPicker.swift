import SwiftUI
import UIKit

/// UIImagePickerController pays its whole view-hierarchy construction on
/// first camera presentation — seconds of visible dead time on device after
/// tapping "Camera". Building the controller while the surrounding sheet is
/// still settling moves that cost off the user's tap. The capture session
/// itself still starts only at presentation, so no camera indicator appears
/// early.
@MainActor
enum CameraPrewarmer {
    private static var prepared: UIImagePickerController?

    static func prewarm() {
        guard prepared == nil, UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        _ = picker.view  // Force the expensive view load now, off the tap path.
        prepared = picker
        Perf.mark("camera.prewarmed")
    }

    static func take() -> UIImagePickerController? {
        defer { prepared = nil }
        return prepared
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker: UIImagePickerController
        if let prepared = CameraPrewarmer.take() {
            picker = prepared
            Perf.mark("camera.present.prewarmed")
        } else {
            picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            Perf.mark("camera.present.cold")
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraPicker

        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // Deliver the original frame; the composer downsamples it off the
            // main thread so the camera dismissal never stutters.
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
