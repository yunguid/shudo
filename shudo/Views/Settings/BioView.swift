import SwiftUI

/// "What Shudo knows about you": the user-owned sections of the coach's
/// memory document, read like a page about you, plus what he's noticed and
/// what changed lately. "Talk to update" hands off to the one mic (the
/// capture bar, bio context); the coach merges what you say and answers with
/// a `profile_update` card (with undo) in Today. Typing is the quiet fallback.
struct BioView: View {
    let coachService: any CoachServing
    let loadRevisions: () async throws -> [CoachMemoryRevision]
    /// Sends a typed update to the coach (text, speech engine id or nil).
    let onSend: (String, String?) -> Void
    /// Starts a bio update on the capture bar's mic (the shell dismisses
    /// this screen first). Nil until bound: the button then opens typing.
    var onTalkToUpdate: (() -> Void)?

    @State private var memory: CoachMemoryDocument?
    @State private var revisions: [CoachMemoryRevision] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isTyping = false
    @State private var typed = ""
    /// The version on screen when an update was sent; cleared when a newer
    /// one lands (or after the last quiet reload).
    @State private var awaitingNewerThan: Int?
    @FocusState private var typingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            page
                #if DEBUG
                .task(id: memory?.version) {
                    // PolishPreview screenshots: `-shudoBioScroll bottom`.
                    guard memory != nil, ProcessInfo.processInfo.arguments.contains("-shudoBioScroll") else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("bio.end", anchor: .bottom)
                }
                .onAppear {
                    // PolishPreview screenshots: `-shudoBioTyping` opens the typed fallback.
                    if ProcessInfo.processInfo.arguments.contains("-shudoBioTyping") { startTyping() }
                }
                #endif
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                content
                Color.clear.frame(height: 1).id("bio.end")
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await load(quietly: true) }
        .background(Design.Color.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { updateBar }
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: isTyping)
        .onChange(of: typingFocused) { _, focused in
            // Keyboard dismissed with nothing typed: back to the big button.
            if !focused, !canSendTyped { isTyping = false }
        }
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            CoachAvatar(size: 44, isThinking: awaitingNewerThan != nil)
            VStack(alignment: .leading, spacing: 4) {
                Text("What Shudo knows about you")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textTertiary)
                    .contentTransition(.opacity)
            }
        }
        .padding(.top, 8)
    }

    private var status: String {
        if awaitingNewerThan != nil { return "Updating…" }
        if loadFailed, memory == nil { return "Couldn’t load. Pull down to retry." }
        guard let memory, memory.version > 0 else { return isLoading ? " " : "Nothing yet" }
        guard let updated = memory.updatedAt else { return " " }
        return "Updated \(updated.formatted(.relative(presentation: .named)))"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let memory, !memory.bio.isEmpty {
            ForEach(memory.bio) { section in
                BioSectionView(title: section.title, markdown: section.markdown)
            }
            if !memory.notes.isEmpty {
                BioSectionView(
                    title: "Noticed lately",
                    markdown: memory.notes.keys.sorted().compactMap { memory.notes[$0] }
                        .map { "- \($0)" }.joined(separator: "\n")
                )
            }
            if !recentChanges.isEmpty { recentChangesView }
        } else if isLoading {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    Capsule().fill(Design.Color.surface2).frame(width: 90, height: 8)
                    Capsule().fill(Design.Color.surface1).frame(height: 12)
                    Capsule().fill(Design.Color.surface1).frame(width: 220, height: 12)
                }
                .shimmering()
            }
            .accessibilityHidden(true)
        } else if !loadFailed {
            Text("Tell him about your training, schedule, food and goals.")
                .font(.body)
                .foregroundStyle(Design.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recentChanges: [CoachMemoryRevision] {
        Array(revisions.filter { $0.changeSummary?.isEmpty == false }.prefix(3))
    }

    private var recentChangesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent changes").eyebrowStyle()
            ForEach(recentChanges) { revision in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(revision.changeSummary ?? "")
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(revision.createdAt.formatted(.relative(presentation: .named)))
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Update bar

    private var updateBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isTyping {
                typingField
                    .transition(.opacity)
            } else {
                Button(action: talk) {
                    Label("Talk to update", systemImage: "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Design.Color.onEmber)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Design.Color.ember, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bio.talk")
                .transition(.opacity)

                if onTalkToUpdate != nil {
                    Button(action: startTyping) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Design.Color.textSecondary)
                            .frame(width: 54, height: 54)
                            .background(Design.Color.surface2, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Type an update")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [Design.Color.canvas.opacity(0), Design.Color.canvas],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    /// Left-handed layout like the capture bar: mic at the left edge, the
    /// field, then send.
    private var typingField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if onTalkToUpdate != nil {
                Button(action: talk) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Design.Color.onEmber)
                        .frame(width: 44, height: 44)
                        .background(Design.Color.emberFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk to update")
            }
            TextField("Tell Shudo what changed", text: $typed, axis: .vertical)
                .lineLimit(1...5)
                .focused($typingFocused)
                .font(.body)
                .foregroundStyle(Design.Color.textPrimary)
                .submitLabel(.send)
                .onSubmit(sendTyped)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .background(Design.Color.surface2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Button(action: sendTyped) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSendTyped ? Design.Color.onEmber : Design.Color.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(canSendTyped ? Design.Color.ember : Design.Color.surface2, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSendTyped)
            .accessibilityLabel("Send bio update")
        }
    }

    private var canSendTyped: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Actions

    private func talk() {
        guard let onTalkToUpdate else {
            startTyping()
            return
        }
        typingFocused = false
        isTyping = false
        onTalkToUpdate()
    }

    private func startTyping() {
        isTyping = true
        typingFocused = true
    }

    private func sendTyped() {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed, nil)
        typed = ""
        typingFocused = false
        isTyping = false
        let sentVersion = memory?.version ?? 0
        awaitingNewerThan = sentVersion
        // The merge takes a few seconds server-side; pick it up when it lands.
        Task {
            for delay in [6.0, 14.0, 24.0] {
                try? await Task.sleep(for: .seconds(delay))
                await load(quietly: true)
                if (memory?.version ?? 0) > sentVersion { break }
            }
            awaitingNewerThan = nil
        }
    }

    // MARK: Loading

    private func load(quietly: Bool = false) async {
        if !quietly { isLoading = memory == nil }
        do {
            let fetched = try await coachService.fetchMemory()
            withAnimation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion)) {
                memory = fetched
            }
            if let history = try? await loadRevisions() { revisions = history }
            loadFailed = false
            if let awaiting = awaitingNewerThan, fetched.version > awaiting { awaitingNewerThan = nil }
        } catch {
            loadFailed = true
        }
        isLoading = false
    }
}

/// One bio section: a small label, then the text as you'd read it.
private struct BioSectionView: View {
    let title: String
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrowStyle()
            BioMarkdownText(markdown: markdown)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum BioPresentation {
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(BioPresentation.lines(markdown).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if line.isBullet {
                        Circle()
                            .fill(Design.Color.textTertiary)
                            .frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
                    }
                    Text(attributed(line.text))
                        .font(.body)
                        .foregroundStyle(Design.Color.textPrimary.opacity(0.92))
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
