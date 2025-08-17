//
//  ContentView.swift
//  shudo
//
//  Created by Luke on 8/16/25.
//

import SwiftUI
import AVFoundation
import PhotosUI
import UIKit

// MARK: - App Config (Dev)
// NOTE: Do NOT put your OpenAI key in the app. Supabase anon key is safe on-device.
private enum AppConfig {
    static let supabaseURL = URL(string: "https://pjbxdeswwcrjbbzkhrvv.supabase.co")!
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBqYnhkZXN3d2NyamJiemtocnZ2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzODY0MDksImV4cCI6MjA3MDk2MjQwOX0.L1HohN1ENfA7wuOGAx7yOT6E5yLM5diNPiUkFQFL1TU"
}

// MARK: - Models
struct MacroTarget: Codable, Equatable {
    var caloriesKcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
}

struct DayTotals: Codable, Equatable {
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var caloriesKcal: Double
    var entryCount: Int

    static let empty = DayTotals(proteinG: 0, carbsG: 0, fatG: 0, caloriesKcal: 0, entryCount: 0)
}

struct Profile: Codable, Equatable {
    var userId: String
    var timezone: String
    var dailyMacroTarget: MacroTarget
}

struct Entry: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var summary: String
    var imageURL: URL?
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var caloriesKcal: Double
}

// MARK: - Services
struct APIService {
    let supabaseUrl: URL
    let supabaseAnonKey: String
    let sessionJWTProvider: () async throws -> String

    func createEntry(text: String?, audioURL: URL?, image: UIImage?, timezone: String) async throws {
        var req = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/create_entry"))
        req.httpMethod = "POST"
        let jwt = try await sessionJWTProvider()
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try makeMultipart(boundary: boundary, text: text, audioURL: audioURL, image: image, timezone: timezone)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "API", code: (resp as? HTTPURLResponse)?.statusCode ?? -1, userInfo: ["body": String(data: data, encoding: .utf8) ?? ""]) 
        }
    }

    private func makeMultipart(boundary: String, text: String?, audioURL: URL?, image: UIImage?, timezone: String) throws -> Data {
        var data = Data()
        func part(_ name: String, _ value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }
        part("timezone", timezone)
        if let t = text, !t.isEmpty { part("text", t) }
        if let url = audioURL, let raw = try? Data(contentsOf: url) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
            data.append(raw); data.append("\r\n".data(using: .utf8)!)
        }
        if let img = image, let jpg = img.jpegData(compressionQuality: 0.92) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            data.append(jpg); data.append("\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }
}

// MARK: - Audio Recorder
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var recordedFileURL: URL?

    private var recorder: AVAudioRecorder?

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
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
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            isRecording = true
            recordedFileURL = url
        } catch {
            print("Audio start error: \(error)")
        }
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
    }

    private static func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("voice_\(UUID().uuidString).m4a")
    }
}

// MARK: - ViewModels
@MainActor
final class TodayViewModel: ObservableObject {
    @Published var profile: Profile?
    @Published var todayTotals: DayTotals = .empty
    @Published var entries: [Entry] = []
    @Published var isPresentingComposer = false
    @Published var isSubmitting = false
    @Published var errorMessage: String?

    let api: APIService

    init(api: APIService) {
        self.api = api
        Task { await loadInitial() }
    }

    func loadInitial() async {
        // Minimal seed until auth & Supabase REST wired
        let target = MacroTarget(caloriesKcal: 2800, proteinG: 180, carbsG: 360, fatG: 72)
        self.profile = Profile(userId: "", timezone: TimeZone.autoupdatingCurrent.identifier, dailyMacroTarget: target)
        self.todayTotals = .empty
        self.entries = []
    }

    func submitEntry(text: String?, audioURL: URL?, image: UIImage?) async {
        guard let tz = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier as String? else { return }
        isSubmitting = true; errorMessage = nil
        do {
            try await api.createEntry(text: text, audioURL: audioURL, image: image, timezone: tz)
            await loadInitial() // optimistic refresh
        } catch {
            errorMessage = (error as NSError).userInfo["body"] as? String ?? error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Views
struct ContentView: View {
    @StateObject private var vm = TodayViewModel(api: APIService(
        supabaseUrl: AppConfig.supabaseURL,
        supabaseAnonKey: AppConfig.supabaseAnonKey,
        sessionJWTProvider: {
            // TODO: Replace with real Supabase auth session access token
            throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Wire up Supabase auth and provide session.accessToken here."])
        }
    ))

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    macroSection
                    Divider()
                    entryList
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button(action: { vm.isPresentingComposer = true }) {
                        Label("Add Entry", systemImage: "plus.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $vm.isPresentingComposer) {
            EntryComposerView { text, audioURL, image in
                await vm.submitEntry(text: text, audioURL: audioURL, image: image)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text(Date.now, style: .date).font(.title2.weight(.semibold))
                Text(TimeZone.autoupdatingCurrent.identifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Macros").font(.headline)
            if let p = vm.profile {
                MacroRingsView(
                    target: p.dailyMacroTarget,
                    current: vm.todayTotals
                )
                .frame(height: 160)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Macro progress")
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)).frame(height: 160)
            }
            if let err = vm.errorMessage { Text(err).font(.caption).foregroundStyle(.red) }
        }
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meals so far").font(.headline)
            if vm.entries.isEmpty {
                Text("No entries yet.").foregroundStyle(.secondary)
            } else {
                ForEach(vm.entries) { entry in
                    EntryCard(entry: entry)
                }
            }
        }
    }
}

// MARK: - Composer
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
                    TextEditor(text: $text).frame(minHeight: 100)
                }
                Section("Image") {
                    PhotosPicker("Choose Photo", selection: $pickedImage, matching: .images)
                    if let img = uiImage {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Section("Voice") {
                    HStack {
                        Button(action: toggleRecord) {
                            Label(audio.isRecording ? "Stop" : "Record", systemImage: audio.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        }
                        Spacer()
                        if let url = audio.recordedFileURL { Text(url.lastPathComponent).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("New Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await onSubmit(text.isEmpty ? nil : text, audio.recordedFileURL, uiImage); dismiss() } }
                        .disabled(uiImage == nil && (text.isEmpty && audio.recordedFileURL == nil))
                }
            }
        }
        .onChange(of: pickedImage) { _, newValue in
            Task { @MainActor in
                guard let item = newValue else { return }
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    uiImage = img
                }
            }
        }
    }

    private func toggleRecord() {
        if audio.isRecording { audio.stopRecording() } else { audio.startRecording() }
    }
}

// MARK: - Components
struct MacroRingsView: View {
    let target: MacroTarget
    let current: DayTotals

    var body: some View {
        GeometryReader { geo in
            let ringSize = min(geo.size.width, geo.size.height)
            ZStack {
                macroRing(progress: current.proteinG / max(target.proteinG, 1), color: .pink, label: "Protein", value: current.proteinG, target: target.proteinG)
                    .frame(width: ringSize, height: ringSize)
                macroRing(progress: current.carbsG / max(target.carbsG, 1), color: .blue, label: "Carbs", value: current.carbsG, target: target.carbsG)
                    .frame(width: ringSize * 0.75, height: ringSize * 0.75)
                macroRing(progress: current.fatG / max(target.fatG, 1), color: .orange, label: "Fat", value: current.fatG, target: target.fatG)
                    .frame(width: ringSize * 0.52, height: ringSize * 0.52)
            }
        }
    }

    private func macroRing(progress: Double, color: Color, label: String, value: Double, target: Double) -> some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text("\(Int(value)) / \(Int(target))")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

struct EntryCard: View {
    let entry: Entry
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.1))
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary).font(.subheadline.weight(.semibold))
                Text("P \(Int(entry.proteinG)) • C \(Int(entry.carbsG)) • F \(Int(entry.fatG)) • \(Int(entry.caloriesKcal)) kcal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

#Preview {
    ContentView()
}
