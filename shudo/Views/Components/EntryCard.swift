import SwiftUI

enum CompletedAnalysisRevealPhase: Int, CaseIterable, Equatable {
    case hidden
    case title
    case protein
    case carbs
    case fat
    case calories
}

enum CompletedAnalysisRevealPlan {
    static let firstDelayNanoseconds: UInt64 = 24_000_000
    static let stepDelayNanoseconds: UInt64 = 62_000_000

    static func phases(reduceMotion: Bool) -> [CompletedAnalysisRevealPhase] {
        reduceMotion
            ? [.calories]
            : Array(CompletedAnalysisRevealPhase.allCases.dropFirst())
    }

    static func delay(before phase: CompletedAnalysisRevealPhase) -> UInt64 {
        phase == .title ? firstDelayNanoseconds : stepDelayNanoseconds
    }
}

enum AnalysisPreviewPresentation {
    static let maximumCharacterCount = 240
    static let frameDelayNanoseconds: UInt64 = 18_000_000

    static func text(
        _ rawValue: String?,
        status: EntryStatus,
        isRetrying: Bool
    ) -> String? {
        guard status == .analyzing, !isRetrying, let rawValue else { return nil }
        let compact = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(maximumCharacterCount))
    }

    static func nextFrame(
        from current: String,
        toward target: String,
        reduceMotion: Bool
    ) -> String {
        guard !reduceMotion, target.hasPrefix(current), current != target else {
            return target
        }
        let remaining = target.count - current.count
        let step = max(1, min(8, (remaining + 17) / 18))
        return String(target.prefix(current.count + step))
    }
}

struct EntryCard: View {
    let entry: Entry
    var isRetrying: Bool = false
    var onRetry: (() -> Void)? = nil
    var animateCompletion = false
    var onCompletionRevealFinished: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealPhase: CompletedAnalysisRevealPhase

    init(
        entry: Entry,
        isRetrying: Bool = false,
        onRetry: (() -> Void)? = nil,
        animateCompletion: Bool = false,
        onCompletionRevealFinished: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.isRetrying = isRetrying
        self.onRetry = onRetry
        self.animateCompletion = animateCompletion
        self.onCompletionRevealFinished = onCompletionRevealFinished
        _revealPhase = State(initialValue: animateCompletion ? .hidden : .calories)
    }
    
    private var hasImage: Bool {
        entry.imageURL != nil
    }

    private var processing: Bool { isRetrying || entry.status.isProcessing }
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Only show thumbnail if there's an image
            if hasImage {
                thumbnail
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.summary)
                        .font(.subheadline)
                        .foregroundStyle(processing ? Design.Color.muted : Design.Color.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.disabled)
                        .opacity(isRevealed(.title) ? 1 : 0)
                        .offset(y: isRevealed(.title) ? 0 : 4)
                    
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if processing {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Capsule()
                                .fill(Design.Color.accentPrimary.opacity(0.32))
                                .frame(width: 24, height: 5)
                                .shimmering()
                            TypewriterStatusText(text: entry.displayStatusMessage)
                        }
                        .foregroundStyle(Design.Color.accentSecondary)

                        if let preview = AnalysisPreviewPresentation.text(
                            entry.analysisPreview,
                            status: entry.status,
                            isRetrying: isRetrying
                        ) {
                            HStack(alignment: .top, spacing: 7) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Design.Color.accentPrimary.opacity(0.75),
                                                Design.Color.accentSecondary.opacity(0.18)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 2)

                                StreamingAnalysisPreviewText(text: preview)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 0.2),
                                value: preview
                            )
                        }
                    }
                } else if entry.status == .failed {
                    HStack(spacing: 10) {
                        Text(entry.displayStatusMessage)
                            .font(.caption)
                            .foregroundStyle(Design.Color.danger)
                            .lineLimit(2)

                        Spacer(minLength: 4)

                        if entry.canRetry, let onRetry {
                            Button(action: onRetry) {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Design.Color.accentSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 10)
                                    .background(
                                        Design.Color.accentPrimary.opacity(0.12),
                                        in: Capsule()
                                    )
                                    // ~44pt tap target beyond the visual pill.
                                    .contentShape(Rectangle().inset(by: -6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Retry meal analysis")
                        }
                    }
                } else if entry.status == .deleting {
                    Text(entry.displayStatusMessage)
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                        .lineLimit(2)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) {
                            completedMacroChips

                            Text("—")
                                .font(.caption2)
                                .foregroundStyle(Design.Color.subtle)

                            completedCalorieText

                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) { completedMacroChips }
                            completedCalorieText
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Protein \(Int(entry.proteinG.rounded()))g, Carbs \(Int(entry.carbsG.rounded()))g, Fat \(Int(entry.fatG.rounded()))g, Calories \(Int(entry.caloriesKcal.rounded()))kcal"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .opacity(processing ? 0.82 : 1.0)
        .task(id: "\(animateCompletion):\(reduceMotion)") {
            guard animateCompletion else {
                revealPhase = .calories
                return
            }

            guard !reduceMotion else {
                revealPhase = .calories
                onCompletionRevealFinished?()
                return
            }

            for phase in CompletedAnalysisRevealPlan.phases(reduceMotion: false) {
                do {
                    try await Task.sleep(
                        nanoseconds: CompletedAnalysisRevealPlan.delay(before: phase)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    revealPhase = phase
                }
            }

            onCompletionRevealFinished?()
        }
    }

    private func isRevealed(_ phase: CompletedAnalysisRevealPhase) -> Bool {
        !animateCompletion || revealPhase.rawValue >= phase.rawValue
    }

    private func macroChip(_ color: Color, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(Int(value.rounded()))g")
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var completedMacroChips: some View {
        macroChip(Design.Color.ringProtein, entry.proteinG)
            .completedResultReveal(isVisible: isRevealed(.protein))
        macroChip(Design.Color.ringCarb, entry.carbsG)
            .completedResultReveal(isVisible: isRevealed(.carbs))
        macroChip(Design.Color.ringFat, entry.fatG)
            .completedResultReveal(isVisible: isRevealed(.fat))
    }

    private var completedCalorieText: some View {
        (
            Text("\(Int(entry.caloriesKcal.rounded()))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
            + Text(" kcal")
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
        )
        .completedResultReveal(isVisible: isRevealed(.calories))
    }

    private var thumbnail: some View {
        AsyncImage(url: entry.imageURL, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            case .empty:
                Rectangle()
                    .fill(Design.Color.elevated)
                    .redacted(reason: .placeholder)
            case .failure:
                Rectangle()
                    .fill(Design.Color.elevated)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(Design.Color.muted)
                    }
            @unknown default:
                Rectangle()
                    .fill(Design.Color.elevated)
            }
        }
        .frame(width: thumb, height: thumb)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.s, style: .continuous)
                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
        .accessibilityLabel("Meal photo")
    }
}

private struct StreamingAnalysisPreviewText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedText = ""

    var body: some View {
        Text(renderedText)
            .font(.caption)
            .foregroundStyle(Design.Color.muted)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Analysis preview: \(text)")
            .accessibilityHint("Updates while nutrition is estimated")
            .task(id: "\(text)|\(reduceMotion)") {
                if reduceMotion {
                    renderedText = text
                    return
                }

                while renderedText != text, !Task.isCancelled {
                    renderedText = AnalysisPreviewPresentation.nextFrame(
                        from: renderedText,
                        toward: text,
                        reduceMotion: false
                    )
                    guard renderedText != text else { return }
                    do {
                        try await Task.sleep(
                            nanoseconds: AnalysisPreviewPresentation.frameDelayNanoseconds
                        )
                    } catch {
                        return
                    }
                }
            }
    }
}

private extension View {
    func completedResultReveal(isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 2.5)
            .offset(y: isVisible ? 0 : 5)
    }
}

private struct TypewriterStatusText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleText = ""

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).opacity(0)
            Text(visibleText)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .task(id: "\(text)|\(reduceMotion)") {
            if reduceMotion {
                visibleText = text
                return
            }
            visibleText = ""
            for character in text {
                guard !Task.isCancelled else { return }
                visibleText.append(character)
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
        }
    }
}
