import SwiftUI
import AVFoundation

struct VoiceRecorderOverlay: View {
    @StateObject private var audio = AudioRecorder()
    @State private var recordingState: RecordingState = .idle
    @State private var recordedData: Data?
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    
    let onSubmit: (Data) async -> Void
    let onDismiss: () -> Void
    
    enum RecordingState {
        case idle
        case recording
        case recorded
        case submitting
    }
    
    var body: some View {
        ZStack {
            // Background
            Design.Color.paper
                .ignoresSafeArea()
                .onTapGesture {
                    if recordingState == .idle {
                        onDismiss()
                    }
                }
            
            // Ambient glow when recording
            if recordingState == .recording {
                RadialGradient(
                    colors: [
                        Design.Color.accentPrimary.opacity(0.15),
                        .clear
                    ],
                    center: .center,
                    startRadius: 50,
                    endRadius: 300
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: recordingState)
            }
            
            VStack(spacing: 40) {
                Spacer()
                
                // Status
                VStack(spacing: 12) {
                    Text(statusText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    
                    if recordingState == .recording || recordingState == .recorded {
                        Text(formatTime(elapsedTime))
                            .font(.system(size: 56, weight: .light, design: .monospaced))
                            .foregroundStyle(recordingState == .recording ? Design.Color.accentPrimary : Design.Color.ink)
                    }
                }
                
                // Waveform
                if recordingState == .recording {
                    WaveformView()
                        .frame(height: 80)
                        .padding(.horizontal, 60)
                }
                
                Spacer()
                
                // Controls
                controlsView
                    .padding(.bottom, 80)
            }
        }
        .onAppear {
            startRecording()
        }
        .onDisappear {
            stopTimer()
            if audio.isRecording {
                audio.stopRecording()
            }
        }
    }
    
    private var statusText: String {
        switch recordingState {
        case .idle: return "Tap to start"
        case .recording: return "Listening…"
        case .recorded: return "Ready to send"
        case .submitting: return "Processing…"
        }
    }
    
    @ViewBuilder
    private var controlsView: some View {
        switch recordingState {
        case .idle:
            Button(action: startRecording) {
                recordButton(isRecording: false)
            }
            
        case .recording:
            Button(action: stopRecording) {
                ZStack {
                    // Pulsing ring
                    Circle()
                        .stroke(Design.Color.accentPrimary.opacity(0.3), lineWidth: 4)
                        .frame(width: 100, height: 100)
                    
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Design.Color.accentPrimary, Design.Color.accentSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 88)
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white)
                        .frame(width: 28, height: 28)
                }
            }
            
        case .recorded:
            HStack(spacing: 32) {
                // Re-record
                Button(action: reRecord) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Design.Color.elevated)
                                .frame(width: 60, height: 60)
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Design.Color.ink)
                        }
                        Text("Redo")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                    }
                }
                
                // Send
                Button(action: submit) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Design.Color.accentPrimary, Design.Color.accentSecondary],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 80, height: 80)
                            Image(systemName: "arrow.up")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        Text("Send")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.ink)
                    }
                }
                
                // Cancel
                Button(action: onDismiss) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Design.Color.elevated)
                                .frame(width: 60, height: 60)
                            Image(systemName: "xmark")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Design.Color.ink)
                        }
                        Text("Cancel")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                    }
                }
            }
            
        case .submitting:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Design.Color.accentPrimary)
                Text("Analyzing your meal…")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.muted)
            }
        }
    }
    
    private func recordButton(isRecording: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Design.Color.accentPrimary, Design.Color.accentSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)
            
            Image(systemName: "waveform")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
    
    private func startRecording() {
        audio.startRecording()
        recordingState = .recording
        elapsedTime = 0
        startTimer()
    }
    
    private func stopRecording() {
        audio.stopRecording()
        stopTimer()
        
        if let url = audio.recordedFileURL,
           let data = try? Data(contentsOf: url) {
            recordedData = data
            recordingState = .recorded
        } else {
            recordingState = .idle
        }
    }
    
    private func reRecord() {
        recordedData = nil
        elapsedTime = 0
        startRecording()
    }
    
    private func submit() {
        guard let data = recordedData else { return }
        recordingState = .submitting
        
        Task {
            await onSubmit(data)
            await MainActor.run {
                onDismiss()
            }
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            elapsedTime += 0.1
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let tenths = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

// Animated waveform
struct WaveformView: View {
    @State private var animating = false
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [Design.Color.accentPrimary, Design.Color.accentSecondary],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3)
                    .frame(height: animating ? CGFloat.random(in: 15...70) : 15)
                    .animation(
                        .easeInOut(duration: 0.25)
                        .repeatForever()
                        .delay(Double(i) * 0.04),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
