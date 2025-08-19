    import Foundation
import AVFoundation

final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var recordedFileURL: URL?

    private var recorder: AVAudioRecorder?

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        // Request mic permission first; handle denial gracefully.
        session.requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if granted == false {
                    self.isRecording = false
                    self.recordedFileURL = nil
                    print("Microphone permission not granted")
                    return
                }
                do {
                    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
                    try session.setActive(true)
                    let url = Self.makeTempURL()
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]
                    self.recorder = try AVAudioRecorder(url: url, settings: settings)
                    self.recorder?.delegate = self
                    self.recorder?.record()
                    self.isRecording = true
                    self.recordedFileURL = url
                } catch {
                    self.isRecording = false
                    self.recordedFileURL = nil
                    print("Audio start error: \(error)")
                }
            }
        }
    }

    func stopRecording() { recorder?.stop(); recorder = nil; isRecording = false }

    private static func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("voice_\(UUID().uuidString).m4a")
    }
}


