import SwiftUI

/// The weekly recap archive: stored `weekly_summaries`, newest first, one
/// row per week; a row opens the full recap.
struct WeeklyRecapList: View {
    let summaries: [WeeklyInsightSummary]
    var isLoading = false

    @State private var selected: WeeklyRecapSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BodyCardHeader(title: "Weekly recaps") {
                if !summaries.isEmpty {
                    Text("\(summaries.count) weeks")
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            .padding(.bottom, 6)
            if summaries.isEmpty {
                Text(isLoading ? "Loading recaps…" : "Your first recap lands Monday morning.")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(summaries.prefix(12).enumerated()), id: \.offset) { index, summary in
                    if index > 0 { HairlineRule() }
                    Button {
                        selected = WeeklyRecapSelection(summary: summary)
                    } label: {
                        row(summary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .cardSurface()
        .sheet(item: $selected) { selection in
            WeeklyRecapDetail(summary: selection.summary)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(Design.Radius.sheet)
        }
    }

    private func row(_ summary: WeeklyInsightSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(WeeklyRecapFormat.range(summary))
                .font(Design.Typeface.numeral(.caption, weight: .bold))
                .foregroundStyle(Design.Color.ember)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 76, alignment: .leading)
                .fixedSize()
            Text(summary.headline)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.textTertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the full recap")
    }
}

struct WeeklyRecapSelection: Identifiable {
    let summary: WeeklyInsightSummary
    var id: Date { summary.weekStart }
}

enum WeeklyRecapFormat {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Summary dates are local days parsed at UTC midnight.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d"
        return formatter
    }()

    /// "Sep 23–29", or "Sep 30–Oct 6" across a month boundary.
    static func range(_ summary: WeeklyInsightSummary) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let sameMonth = calendar.isDate(summary.weekStart, equalTo: summary.weekEnd, toGranularity: .month)
        let end = sameMonth ? dayOnly.string(from: summary.weekEnd) : formatter.string(from: summary.weekEnd)
        return "\(formatter.string(from: summary.weekStart))–\(end)"
    }
}

struct WeeklyRecapDetail: View {
    let summary: WeeklyInsightSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Week of \(WeeklyRecapFormat.range(summary))").eyebrowStyle(Design.Color.ember)
                    Text(summary.headline)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !summary.narrative.isEmpty {
                    Text(summary.narrative)
                        .font(.body)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                list("What worked", summary.patterns, symbol: "checkmark")
                list("Next week", summary.suggestions, symbol: "arrow.right")
                if !summary.repeatedFoods.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On repeat").eyebrowStyle()
                        ForEach(summary.repeatedFoods, id: \.name) { food in
                            HStack {
                                Text(food.name).foregroundStyle(Design.Color.textPrimary)
                                Spacer()
                                Text("×\(food.count)")
                                    .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                                    .foregroundStyle(Design.Color.textTertiary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Design.Color.surface1.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).eyebrowStyle()
                ForEach(items, id: \.self) { item in
                    Label {
                        Text(item).foregroundStyle(Design.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: symbol).foregroundStyle(Design.Color.ember)
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}
