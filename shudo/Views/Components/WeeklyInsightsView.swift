import SwiftUI

struct WeeklyInsightsView: View {
    let summary: WeeklyInsightSummary?
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    init(
        summary: WeeklyInsightSummary?,
        isLoading: Bool,
        errorMessage: String? = nil,
        onRetry: @escaping () -> Void = { }
    ) {
        self.summary = summary
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weekly insights")
                        .font(.headline)
                        .foregroundStyle(Design.Color.ink)
                    Text(summary.map(periodText) ?? "Latest summary")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Design.Color.accentSecondary)
            }

            if isLoading {
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().fill(Design.Color.elevated).frame(width: 210, height: 10)
                    Capsule().fill(Design.Color.elevated).frame(height: 8)
                    Capsule().fill(Design.Color.elevated).frame(width: 240, height: 8)
                }
                .shimmering()
                .accessibilityLabel("Loading weekly insights")
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.accentSecondary)
                        .buttonStyle(.plain)
                }
            } else if let summary {
                Text(summary.headline.isEmpty ? "Your week at a glance" : summary.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !summary.narrative.isEmpty {
                    Text(summary.narrative)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !summary.repeatedFoods.isEmpty {
                    insightGroup(
                        title: "Repeated foods",
                        items: summary.repeatedFoods.prefix(4).map {
                            "\($0.name) · \($0.count) logged meals"
                        },
                        systemImage: "repeat"
                    )
                }

                if !summary.patterns.isEmpty {
                    insightGroup(title: "Patterns", items: summary.patterns, systemImage: "waveform.path.ecg")
                }
                if !summary.suggestions.isEmpty {
                    insightGroup(title: "Try next", items: summary.suggestions, systemImage: "arrow.right.circle")
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No weekly summary yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    Text("Keep logging meals and the latest patterns and practical next steps can appear here.")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        )
    }

    private func insightGroup(title: String, items: [String], systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.muted)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Design.Color.accentSecondary)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(item)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private func periodText(_ summary: WeeklyInsightSummary) -> String {
        let formatter = Self.periodFormatter
        return "\(formatter.string(from: summary.weekStart))–\(formatter.string(from: summary.weekEnd))"
    }
}
