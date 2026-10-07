import SwiftUI

/// "What Shudo knows about you": Luke's bio (the user-owned sections of the
/// coach's memory document), rendered as readable cards, with "Talk to
/// update" — a dictation sent to the coach with `context_hint: "bio"` so he
/// merges it into the right sections and answers with a `profile_update`
/// card (with undo) in Today's thread. Recent revisions show what changed.
struct BioView: View {
    let coachService: any CoachServing
    let loadRevisions: () async throws -> [CoachMemoryRevision]
    /// Sends the update to the coach (text, speech engine id or nil).
    let onSend: (String, String?) -> Void

    @StateObject private var voiceHolder = UnobservedHolder(VoiceTranscriber(profile: .coach))
    @State private var memory: CoachMemoryDocument?
    @State private var revisions: [CoachMemoryRevision] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isTalking = false
    @State private var typed = ""
    @State private var sentMessage: String?
    @State private var showsNotes = false
    @FocusState private var typingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                if isTalking { talkPanel.transition(.opacity.combined(with: .move(edge: .top))) }
                if let sentMessage {
                    Label(sentMessage, systemImage: "checkmark.bubble.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Design.Color.positive)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.danger)
                }
                sections
                if let notes = memory?.notes, !notes.isEmpty { notesCard(notes) }
                if !revisions.isEmpty { revisionsCard }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Design.Color.canvas.ignoresSafeArea())
        .navigationTitle("Your bio")
        .navigationBarTitleDisplayMode(.inline)
        .animation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion), value: isTalking)
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: sentMessage)
        .task { await load() }
        .onDisappear { voiceHolder.value.cancel() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CoachAvatar(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What Shudo knows about you")
                        .font(.headline)
                        .foregroundStyle(Design.Color.textPrimary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            Text("He reads this before every text. Tell him what changed — new schedule, a tweaked shoulder, a new goal — and he’ll update it.")
                .font(.subheadline)
                .foregroundStyle(Design.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isTalking.toggle()
                if !isTalking { voiceHolder.value.cancel() }
            } label: {
                Label(isTalking ? "Done talking" : "Talk to update", systemImage: isTalking ? "xmark" : "mic.fill")
            }
            .buttonStyle(CardButtonStyle(prominent: !isTalking))
            .accessibilityIdentifier("bio.talk")
        }
        .padding(16)
        .cardSurface(radius: Design.Radius.cardLarge)
        .padding(.top, 8)
    }

    private var subtitle: String {
        guard let memory, memory.version > 0 else { return isLoading ? "Loading…" : "Nothing yet" }
        if let updated = memory.updatedAt {
            return "Version \(memory.version) · updated \(updated.formatted(.relative(presentation: .named)))"
        }
        return "Version \(memory.version)"
    }

    // MARK: Talk

    private var talkPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VoiceCaptureCard(
                voice: voiceHolder.value,
                style: .bio,
                onWillStart: {
                    typingFocused = false
                    sentMessage = nil
                },
                onTake: { take in send(take.text, engine: take.engine.rawValue) }
            )
            HStack(spacing: 8) {
                TextField("Or type it…", text: $typed, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typingFocused)
                    .font(.body)
                    .foregroundStyle(Design.Color.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Design.Color.surface2, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                Button {
                    send(typed, engine: nil)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Design.Color.onEmber)
                        .frame(width: 36, height: 36)
                        .background(Design.Color.ember, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send bio update")
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func send(_ text: String, engine: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed, engine)
        typed = ""
        typingFocused = false
        sentMessage = "Sent to Shudo. He’ll update your bio and show the changes in Today."
        // The merge takes a few seconds server-side; pick it up when it lands.
        Task {
            for delay in [8.0, 20.0] {
                try? await Task.sleep(for: .seconds(delay))
                await load(quietly: true)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var sections: some View {
        if let memory, !memory.bio.isEmpty {
            ForEach(memory.bio) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title).eyebrowStyle(Design.Color.ember)
                    BioMarkdownText(markdown: section.markdown)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                .accessibilityElement(children: .combine)
            }
            let missing = BioPresentation.missingSections(in: memory)
            if !missing.isEmpty {
                Text("Not covered yet: \(missing.joined(separator: ", ")). Tell Shudo and he’ll add them.")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if isLoading {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .fill(Design.Color.surface1)
                    .frame(height: 96)
                    .shimmering()
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shudo doesn’t know much yet")
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                Text("Tap “Talk to update” and tell him about your training, schedule, food and goals.")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func notesCard(_ notes: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Design.Motion.snap) { showsNotes.toggle() }
            } label: {
                HStack {
                    Text("What he’s noticed").eyebrowStyle()
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Design.Color.textTertiary)
                        .rotationEffect(.degrees(showsNotes ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsNotes {
                ForEach(notes.keys.sorted(), id: \.self) { key in
                    BioMarkdownText(markdown: notes[key] ?? "")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var revisionsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent changes").eyebrowStyle()
                .padding(.bottom, 6)
            ForEach(Array(revisions.prefix(6).enumerated()), id: \.element.id) { index, revision in
                if index > 0 { HairlineRule() }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("v\(revision.version)")
                        .font(Design.Typeface.numeral(.caption, weight: .bold))
                        .foregroundStyle(Design.Color.ember)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(revision.changeSummary ?? revision.sourceLabel)
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(revision.sourceLabel) · \(revision.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(Design.Color.textTertiary)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: Loading

    private func load(quietly: Bool = false) async {
        if !quietly { isLoading = memory == nil }
        do {
            memory = try await coachService.fetchMemory()
            if let history = try? await loadRevisions() { revisions = history }
            errorMessage = nil
        } catch {
            if !quietly { errorMessage = "Couldn’t load your bio. Pull to try again later." }
        }
        isLoading = false
    }
}

extension VoiceCaptureCard.Style {
    static let bio = VoiceCaptureCard.Style(
        idleHeadline: "Tell Shudo what changed",
        idleDetail: "Tap to talk — it goes straight to him",
        startLabel: "Start bio update",
        stopLabel: "Stop and send",
        stopDetail: .elapsed,
        idleIcon: "mic.fill",
        meterTint: Design.Color.ember,
        meterHeight: 52,
        showsBackground: false
    )
}

enum BioPresentation {
    /// Known bio sections the document doesn't cover yet (display titles).
    static func missingSections(in memory: CoachMemoryDocument) -> [String] {
        let present = Set(memory.bio.map(\.key))
        return CoachBioSectionKey.allCases
            .filter { !present.contains($0.rawValue) && $0 != .handleWithCare }
            .map(\.title)
    }

    /// Markdown bullets become "•" lines; inline emphasis is kept.
    static func lines(_ markdown: String) -> [(isBullet: Bool, text: String)] {
        markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                    return (true, String(line.dropFirst(marker.count)))
                }
                return (false, line.hasPrefix("#") ? line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : line)
            }
    }
}

/// Renders a bio section: paragraphs and bullets with inline markdown.
struct BioMarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(BioPresentation.lines(markdown).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if line.isBullet {
                        Circle()
                            .fill(Design.Color.honey)
                            .frame(width: 4, height: 4)
                            .offset(y: -3)
                    }
                    Text(attributed(line.text))
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
