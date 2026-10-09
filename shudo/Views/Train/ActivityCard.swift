import SwiftUI

// MARK: - ActivityCard
//
// One workout, minimal: kind tile, title (+ PR badge), one stat line —
// "Bench press 185×8 · 61 min" or "32 min · 3.1 mi". While it's being
// read the stat line is the session itself, shimmering. Reused by the
// Today thread (fixed to `Design.Layout.threadCardWidth` there) and the
// Train tab's history list.

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
        HStack(alignment: .center, spacing: 12) {
            ActivityKindTile(kind: activity.kind, isProcessing: activity.isProcessing, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activity.title)
                        .font(Design.Typeface.text(.subheadline, weight: .semibold))
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
                    .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay {
            if activity.isNotSent {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .stroke(Design.Color.danger.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        if activity.isNotSent {
            Text("Not sent")
                .font(Design.Typeface.text(.footnote, weight: .medium))
                .foregroundStyle(Design.Color.danger)
        } else if activity.isProcessing {
            Text(ActivityCard.readingLine(for: activity))
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.textSecondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .shimmering()
        } else if activity.status == .failed {
            Text("Couldn’t read this one")
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.danger)
        } else if let line = ActivitySummaryFormatter.statLine(for: activity, units: units) {
            Text(line)
                .font(Design.Typeface.numeral(.footnote, weight: .medium))
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

/// Tinted icon pad by activity kind.
struct ActivityKindTile: View {
    let kind: ActivityKind
    var isProcessing = false
    var size: CGFloat = 44

    static func tint(for kind: ActivityKind) -> Color {
        switch kind {
        case .strength, .hiit: return Design.Color.ember
        case .run, .cardio, .cycle, .swim: return Design.Color.macroCarbs
        case .walk, .mobility: return Design.Color.macroFat
        case .sport, .other: return Design.Color.honey
        }
    }

    var body: some View {
        let tint = Self.tint(for: kind)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(tint.opacity(0.13))
            .overlay {
                Image(systemName: kind.symbolName)
                    .font(.custom(Design.Typeface.faceName(.semibold), fixedSize: size * 0.42))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: isProcessing)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
