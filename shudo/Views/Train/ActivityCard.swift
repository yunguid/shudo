import SwiftUI

// MARK: - ActivityCard
//
// One workout in a state that needs a card: sending, being read, couldn't
// be read, or not sent (with Retry / Discard). Shaped like the thread's
// `WorkoutReceiptCard` — kind glyph and title, one line beneath, the same
// warm receipt surface — so when a log settles in the Today thread the
// receipt takes its place without the card changing shape. While it's read
// the line is the session itself, shimmering. Used by the Today thread
// (fixed to `Design.Layout.threadCardWidth` there) and, for unsent logs,
// the Train history.

struct ActivityCard: View {
    let activity: Activity
    var units: String
    var onRetry: (() -> Void)?
    var onDiscard: (() -> Void)?

    init(
        activity: Activity,
        units: String = "imperial",
        onRetry: (() -> Void)? = nil,
        onDiscard: (() -> Void)? = nil
    ) {
        self.activity = activity
        self.units = units
        self.onRetry = onRetry
        self.onDiscard = onDiscard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: activity.kind.symbolName)
                    .font(Design.Typeface.text(.caption, weight: .bold))
                    .foregroundStyle(ActivityKindTile.tint(for: activity.kind))
                    .symbolEffect(.pulse, options: .repeating, isActive: activity.isProcessing)
                    .accessibilityHidden(true)
                Text(activity.title)
                    .font(Design.Typeface.text(.subheadline, weight: .medium))
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(1)
                if !activity.prs.isEmpty {
                    TrainPRBadge(count: activity.prs.count)
                }
            }
            statusLine
            if activity.isNotSent, onRetry != nil || onDiscard != nil {
                HStack(spacing: 8) {
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(TrainCapsuleButtonStyle(prominent: true))
                    }
                    if let onDiscard {
                        Button("Discard", action: onDiscard)
                            .buttonStyle(TrainCapsuleButtonStyle(prominent: false))
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .receiptSurface()
        .overlay {
            if activity.isNotSent {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .strokeBorder(Design.Color.danger.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        if activity.isNotSent {
            Text("Not sent")
                .font(Design.Typeface.text(.caption, weight: .medium))
                .foregroundStyle(Design.Color.danger)
        } else if activity.isProcessing {
            Text(ActivityCard.readingLine(for: activity))
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.textSecondary)
                .lineLimit(2)
                .contentTransition(.opacity)
                .shimmering()
        } else if activity.status == .failed {
            Text("Couldn’t read this one")
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.danger)
        } else if let line = ActivitySummaryFormatter.statLine(for: activity, units: units) {
            Text(line)
                .font(Design.Typeface.numeral(.caption))
                .foregroundStyle(Design.Color.textSecondary)
                .lineLimit(2)
        }
    }

    /// What a log shows while it's read: the quick read when the server has
    /// one, otherwise the words as said — never a narrated status.
    static func readingLine(for activity: Activity) -> String {
        activity.analysisPreview
            ?? activity.inputText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Logging…"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Building blocks (shared by the Train views)

/// The kind glyph's tint (the old icon tile is gone; cards and receipts
/// now show the bare glyph).
enum ActivityKindTile {
    static func tint(for kind: ActivityKind) -> Color {
        switch kind {
        case .strength, .hiit: return Design.Color.ember
        case .run, .cardio, .cycle, .swim: return Design.Color.macroCarbs
        case .walk, .mobility: return Design.Color.macroFat
        case .sport, .other: return Design.Color.honey
        }
    }
}

struct TrainPRBadge: View {
    var count: Int = 1

    var body: some View {
        Text(count > 1 ? "\(count) PRs" : "PR")
            .font(Design.Typeface.eyebrow)
            .foregroundStyle(Design.Color.onEmber)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Design.Color.emberFill, in: Capsule())
            .accessibilityLabel(count > 1 ? "\(count) personal records" : "Personal record")
    }
}

struct TrainCapsuleButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typeface.text(.footnote, weight: .semibold))
            .foregroundStyle(prominent ? Design.Color.onEmber : Design.Color.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                if prominent {
                    Capsule().fill(Design.Color.emberFill)
                } else {
                    Capsule().fill(Design.Color.surface3)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
