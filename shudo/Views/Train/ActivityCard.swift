import SwiftUI

// MARK: - ActivityCard
//
// One workout as a card: tinted kind tile, title, "Bench press 185×8 · +4
// lifts" or "32 min · 3.1 mi", a burn chip styled unlike intake, PR badge,
// and live processing / not-sent states. Reused by the Today thread (wrap in
// `.frame(maxWidth: 300)` there) and the Train tab's history list.

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
        HStack(alignment: .top, spacing: 12) {
            ActivityKindTile(kind: activity.kind, isProcessing: activity.isProcessing)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !activity.prs.isEmpty {
                        TrainPRBadge(count: activity.prs.count)
                    }
                    Text(activity.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                        .monospacedDigit()
                }
                statusLine
                if activity.status == .complete, activity.localState == nil, hasMeta {
                    HStack(spacing: 8) {
                        if let duration = ActivitySummaryFormatter.metaDuration(for: activity) {
                            Label(duration, systemImage: "timer")
                                .labelStyle(TrainInlineLabelStyle())
                                .font(Design.Typeface.numeral(.caption, weight: .semibold))
                                .foregroundStyle(Design.Color.textSecondary)
                        }
                        if let kcal = activity.activeKcal, kcal >= 1 {
                            BurnChip(kcal: kcal)
                        }
                    }
                }
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
                    .padding(.top, 2)
                }
            }
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

    private var hasMeta: Bool {
        ActivitySummaryFormatter.metaDuration(for: activity) != nil || (activity.activeKcal ?? 0) >= 1
    }

    @ViewBuilder
    private var statusLine: some View {
        switch activity.localState {
        case .sending:
            Text("Sending…")
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
                .shimmering()
        case .notSent:
            Text(activity.errorMessage ?? ActivityLoggingController.notSentStatusMessage)
                .font(.footnote)
                .foregroundStyle(Design.Color.danger)
                .fixedSize(horizontal: false, vertical: true)
        case .stalled(let message):
            Text(activity.analysisPreview ?? message)
                .font(.footnote)
                .foregroundStyle(Design.Color.textTertiary)
                .lineLimit(2)
        case .none:
            switch activity.status {
            case .processing:
                Text(activity.analysisPreview ?? "Reading your session…")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .shimmering()
            case .failed:
                Text(activity.errorMessage.map { "Couldn’t read this one — \($0)" } ?? "Couldn’t read this one")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.danger)
                    .lineLimit(2)
            case .complete:
                if let subtitle = ActivitySummaryFormatter.subtitle(for: activity, units: units) {
                    Text(subtitle)
                        .font(Design.Typeface.numeral(.footnote, weight: .medium))
                        .foregroundStyle(Design.Color.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }
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
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(
                colors: [tint.opacity(0.30), tint.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(tint.opacity(0.28), lineWidth: 0.5))
            .overlay {
                Image(systemName: kind.symbolName)
                    .font(.system(size: size * 0.42, weight: .semibold))
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
            .tracking(0.6)
            .foregroundStyle(Design.Color.onEmber)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Design.Color.emberFill, in: Capsule())
            .accessibilityLabel(count > 1 ? "\(count) personal records" : "Personal record")
    }
}

/// Burned energy, outlined so it never reads like an intake chip.
struct BurnChip: View {
    let kcal: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.caption2.weight(.bold))
            Text(ActivitySummaryFormatter.burnText(kcal: kcal))
                .font(Design.Typeface.numeral(.caption, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Design.Color.ember)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().stroke(Design.Color.ember.opacity(0.45), lineWidth: 1))
        .accessibilityLabel("\(Int(kcal.rounded())) calories burned")
    }
}

struct TrainInlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.caption2.weight(.semibold))
            configuration.title
        }
    }
}

struct TrainCapsuleButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
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
