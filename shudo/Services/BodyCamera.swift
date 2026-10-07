import AVFoundation
import AudioToolbox
import UIKit
import Vision

// MARK: - Pose alignment (pure policy)

enum BodyPoseJoint: String, CaseIterable, Sendable {
    case nose, neck, leftShoulder, rightShoulder, leftHip, rightHip
    case leftWrist, rightWrist, leftAnkle, rightAnkle
}

/// Joints in normalized image space, origin top-left (UIKit convention).
struct BodyPoseObservation: Equatable, Sendable {
    var joints: [BodyPoseJoint: CGPoint]
}

enum BodyPoseHint: Equatable, Sendable {
    case noBody, stepBack, comeCloser, stepLeft, stepRight, armsOut, aligned

    var text: String {
        switch self {
        case .noBody: "Get in the frame"
        case .stepBack: "Step back, feet in frame"
        case .comeCloser: "Come a little closer"
        case .stepLeft: "Step to your left"
        case .stepRight: "Step to your right"
        case .armsOut: "Arms off your sides"
        case .aligned: "Locked in"
        }
    }

    var spoken: String {
        switch self {
        case .noBody: "I can't see you yet."
        case .stepBack: "Step back. Get your feet in."
        case .comeCloser: "Come a bit closer."
        case .stepLeft: "Step to your left."
        case .stepRight: "Step to your right."
        case .armsOut: "Arms off your sides."
        case .aligned: "Locked in. Hold it."
        }
    }
}

/// Standing-frame guidance from a Vision body pose. Positions are in the
/// camera's (unmirrored) frame, so "the subject is left of center" means
/// they should step to *their* left, for either camera.
enum BodyPoseAlignmentPolicy {
    static let centerTolerance = 0.06
    static let edgeMargin = 0.03
    /// Head-to-ankle span as a fraction of frame height.
    static let minimumBodyHeight = 0.55
    static let wristClearance = 0.045

    static func hint(_ observation: BodyPoseObservation?) -> BodyPoseHint {
        guard let joints = observation?.joints, !joints.isEmpty,
            let hips = midpoint(joints[.leftHip], joints[.rightHip])
        else { return .noBody }
        guard let head = joints[.nose] ?? joints[.neck],
            let feet = midpoint(joints[.leftAnkle], joints[.rightAnkle])
        else { return .stepBack }
        if head.y < edgeMargin || feet.y > 1 - edgeMargin { return .stepBack }
        if feet.y - head.y < minimumBodyHeight { return .comeCloser }
        if hips.x < 0.5 - centerTolerance { return .stepLeft }
        if hips.x > 0.5 + centerTolerance { return .stepRight }
        let pinned = [(BodyPoseJoint.leftWrist, BodyPoseJoint.leftHip), (.rightWrist, .rightHip)]
            .contains { wrist, hip in
                guard let wrist = joints[wrist], let hip = joints[hip] else { return false }
                return abs(wrist.x - hip.x) < wristClearance
            }
        return pinned ? .armsOut : .aligned
    }

    private static func midpoint(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
        switch (a, b) {
        case let (a?, b?): CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case let (a?, nil): a
        case let (nil, b?): b
        default: nil
        }
    }
}

enum BodyCameraTimer: Int, CaseIterable, Identifiable, Sendable {
    case three = 3, five = 5, ten = 10
    var id: Int { rawValue }
}

// MARK: - Capture engine (AVFoundation + Vision, off the main thread)

enum BodyCameraError: LocalizedError {
    case notRunning, noPhoto
    var errorDescription: String? {
        switch self {
        case .notRunning: "The camera isn't running."
        case .noPhoto: "That shot didn't come through. Try again."
        }
    }
}

/// Owns the capture session on a private queue. Locked for repeatable
/// physique shots: built-in wide lens at 1x, 4:3 photo preset, flash off,
/// front-camera stills saved un-mirrored. A throttled video output feeds
/// Vision body-pose detection (~6 Hz) for the alignment hint.
final class BodyCaptureEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "luke.shudo.body-camera")
    private let frameQueue = DispatchQueue(label: "luke.shudo.body-camera.frames")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var photoCompletion: ((Result<Data, Error>) -> Void)?
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let lock = NSLock()
    private var lastPoseTime: CFAbsoluteTime = 0
    private var poseHandlerStorage: (@Sendable (BodyPoseObservation?) -> Void)?

    static let poseInterval: CFAbsoluteTime = 1.0 / 6.0

    var poseHandler: (@Sendable (BodyPoseObservation?) -> Void)? {
        get { lock.withLock { poseHandlerStorage } }
        set { lock.withLock { poseHandlerStorage = newValue } }
    }

    static func hasCamera(_ position: AVCaptureDevice.Position) -> Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) != nil
    }

    func start(position: AVCaptureDevice.Position, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let configured = configure(position: position)
            if configured, !session.isRunning { session.startRunning() }
            completion(configured && session.isRunning)
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [self] in
            guard session.isRunning, photoCompletion == nil else {
                completion(.failure(BodyCameraError.notRunning))
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            if photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
            settings.photoQualityPrioritization = .balanced
            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            photoCompletion = completion
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configure(position: AVCaptureDevice.Position) -> Bool {
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        if let currentInput { session.removeInput(currentInput) }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        currentInput = input

        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video),
            connection.isVideoRotationAngleSupported(90)
        {
            connection.videoRotationAngle = 90
        }
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = 1
            device.unlockForConfiguration()
        }
        return true
    }
}

extension BodyCaptureEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<Data, Error>
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(data)
        } else {
            result = .failure(BodyCameraError.noPhoto)
        }
        queue.async { [self] in
            let completion = photoCompletion
            photoCompletion = nil
            completion?(result)
        }
    }
}

extension BodyCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let handler = poseHandler else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPoseTime >= Self.poseInterval else { return }
        lastPoseTime = now
        let orientation: CGImagePropertyOrientation = connection.videoRotationAngle == 90 ? .up : .right
        let request = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation)
        guard (try? request.perform([poseRequest])) != nil else { return handler(nil) }
        handler(poseRequest.results?.first.map(Self.observation))
    }

    private static let jointMap: [(VNHumanBodyPoseObservation.JointName, BodyPoseJoint)] = [
        (.nose, .nose), (.neck, .neck), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]

    private static func observation(_ pose: VNHumanBodyPoseObservation) -> BodyPoseObservation {
        var joints: [BodyPoseJoint: CGPoint] = [:]
        for (name, joint) in jointMap {
            guard let point = try? pose.recognizedPoint(name), point.confidence >= 0.3 else { continue }
            // Vision is bottom-left origin; flip to top-left.
            joints[joint] = CGPoint(x: point.location.x, y: 1 - point.location.y)
        }
        return BodyPoseObservation(joints: joints)
    }
}

// MARK: - Main-actor facade for SwiftUI

@MainActor
final class BodyCameraController: ObservableObject {
    enum State: Equatable { case idle, starting, running, denied, unavailable }

    @Published private(set) var state: State = .idle
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var poseHint: BodyPoseHint = .noBody

    let engine = BodyCaptureEngine()
    var session: AVCaptureSession { engine.session }

    static var hasAnyCamera: Bool {
        BodyCaptureEngine.hasCamera(.back) || BodyCaptureEngine.hasCamera(.front)
    }

    func start() async {
        guard state != .running, state != .starting else { return }
        guard Self.hasAnyCamera else {
            state = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        case .denied, .restricted:
            state = .denied
            return
        default:
            break
        }
        if !BodyCaptureEngine.hasCamera(position) { position = position == .back ? .front : .back }
        state = .starting
        engine.poseHandler = { [weak self] observation in
            let hint = BodyPoseAlignmentPolicy.hint(observation)
            Task { @MainActor [weak self] in
                guard let self, self.poseHint != hint else { return }
                self.poseHint = hint
            }
        }
        let engine = engine
        let position = position
        let running = await withCheckedContinuation { continuation in
            engine.start(position: position) { continuation.resume(returning: $0) }
        }
        state = running ? .running : .unavailable
    }

    func stop() {
        engine.poseHandler = nil
        engine.stop()
        if state == .running || state == .starting { state = .idle }
    }

    func flip() async {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        guard BodyCaptureEngine.hasCamera(next) else { return }
        position = next
        poseHint = .noBody
        let engine = engine
        let running = await withCheckedContinuation { continuation in
            engine.start(position: next) { continuation.resume(returning: $0) }
        }
        state = running ? .running : .unavailable
    }

    func capture() async throws -> UIImage {
        let engine = engine
        let data = try await withCheckedThrowingContinuation { continuation in
            engine.capture { continuation.resume(with: $0) }
        }
        guard let image = UIImage(data: data) else { throw BodyCameraError.noPhoto }
        return ImageProcessor.normalizedForUpload(image)
    }
}

// MARK: - Countdown voice

/// Spoken countdown + guidance for a phone propped across the room. Ducks
/// other audio for the prompt and lets it resume afterwards.
@MainActor
final class BodyCameraVoice {
    private let synthesizer = AVSpeechSynthesizer()
    private var isActive = false
    var isEnabled = true

    func say(_ text: String) {
        guard isEnabled else { return }
        activate()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
    }

    /// Short system tick so the count is audible even with voice off.
    func tick() {
        AudioServicesPlaySystemSound(1103)
    }

    func deactivate() {
        synthesizer.stopSpeaking(at: .immediate)
        guard isActive else { return }
        isActive = false
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activate() {
        guard !isActive else { return }
        isActive = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
    }
}
