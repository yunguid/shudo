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
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    if recordingState == .idle {
                        onDismiss()
                    }
                }
            
            VStack(spacing: 32) {
                Spacer()
                
                // Status text
                Text(statusText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                
                // Timer display
                if recordingState == .recording || recordingState == .recorded {
                    Text(formatTime(elapsedTime))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(.white)
                }
                
                // Waveform indicator when recording
                if recordingState == .recording {
                    WaveformView()
                        .frame(height: 60)
                        .padding(.horizontal, 40)
                }
                
                Spacer()
                
                // Controls
                controlsView
                    .padding(.bottom, 60)
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
        case .recording: return "Recording..."
        case .recorded: return "Ready to send"
        case .submitting: return "Sending..."
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
                    Circle()
                        .fill(Design.Color.danger)
                        .frame(width: 80, height: 80)
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white)
                        .frame(width: 28, height: 28)
                }
            }
            
        case .recorded:
            HStack(spacing: 40) {
                // Re-record button
                Button(action: reRecord) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Design.Color.fill)
                                .frame(width: 64, height: 64)
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        Text("Re-record")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                    }
                }
                
                // Send button
                Button(action: submit) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Design.Color.accentPrimary)
                                .frame(width: 80, height: 80)
                            Image(systemName: "paperplane.fill")
                                .font(.title.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        Text("Send")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                    }
                }
                
                // Cancel button
                Button(action: onDismiss) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Design.Color.fill)
                                .frame(width: 64, height: 64)
                            Image(systemName: "xmark")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        Text("Cancel")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                    }
                }
            }
            
        case .submitting:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }
    
    private func recordButton(isRecording: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Design.Color.danger)
                .frame(width: 80, height: 80)
            
            Circle()
                .fill(.white)
                .frame(width: 32, height: 32)
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
        
        // Read the audio data immediately
        if let url = audio.recordedFileURL,
           let data = try? Data(contentsOf: url) {
            recordedData = data
            recordingState = .recorded
        } else {
            // Failed to get audio, go back to idle
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

// Simple animated waveform
struct WaveformView: View {
    @State private var animating = false
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<20, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Design.Color.accentPrimary)
                    .frame(width: 4)
                    .frame(height: animating ? CGFloat.random(in: 10...50) : 10)
                    .animation(
                        .easeInOut(duration: 0.3)
                        .repeatForever()
                        .delay(Double(i) * 0.05),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
