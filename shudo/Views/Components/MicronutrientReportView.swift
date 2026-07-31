import SwiftUI

struct MicronutrientReportView: View {
    let report: WeeklyMicronutrientReport
    let period: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                coverageCard
                if !report.highlights.isEmpty {
                    copyGroup(title: "Highlights", items: report.highlights, icon: "sparkles")
                }
                nutrientGroup(
                    title: "Vitamins", nutrients: report.nutrients.filter { $0.category == "vitamin" })
                nutrientGroup(
                    title: "Minerals", nutrients: report.nutrients.filter { $0.category == "mineral" })
                nutrientGroup(
                    title: "Fiber & fats", nutrients: report.nutrients.filter { $0.category == "other" })
                if !report.suggestions.isEmpty {
                    copyGroup(title: "Try next week", items: report.suggestions, icon: "leaf")
                }
                Text(report.caveat)
                    .font(.caption)
                    .foregroundStyle(Design.Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(20)
            .padding(.bottom, 28)
        }
        .background(Design.Color.paper)
        .navigationTitle("Micronutrients")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(period)
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
            Text(
                "Based on \(report.mealsLogged) meal\(report.mealsLogged == 1 ? "" : "s") across \(report.daysLogged) logged day\(report.daysLogged == 1 ? "" : "s")."
            )
            .font(.footnote)
            .foregroundStyle(Design.Color.muted)
            Label("Weekly estimates, not lab measurements", systemImage: "info.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(Design.Color.accentSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Design.Color.glassFill, in: RoundedRectangle(cornerRadius: Design.Radius.card))
    }

    @ViewBuilder
    private func nutrientGroup(title: String, nutrients: [WeeklyMicronutrient]) -> some View {
        if !nutrients.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
                VStack(spacing: 0) {
                    ForEach(Array(nutrients.enumerated()), id: \.element.id) { index, nutrient in
                        nutrientRow(nutrient)
                        if index < nutrients.count - 1 { HairlineRule().padding(.leading, 16) }
                    }
                }
                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.l))
            }
        }
    }

    private func nutrientRow(_ nutrient: WeeklyMicronutrient) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(nutrient.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                Spacer()
                Text(statusLabel(nutrient.status))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(statusColor(nutrient.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(nutrient.status).opacity(0.12), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(amountText(nutrient.estimatedDailyAmount))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.ink)
                    .monospacedDigit()
                Text("\(nutrient.unit)/day · \(nutrient.percentReference)% reference")
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
            }
            ProgressView(value: min(1, max(0, Double(nutrient.percentReference) / 100)))
                .tint(statusColor(nutrient.status))
            if !nutrient.evidence.isEmpty {
                Text("From: " + nutrient.evidence.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(Design.Color.subtle)
                    .lineLimit(3)
            }
            Text("\(nutrient.confidence.capitalized) confidence")
                .font(.caption2)
                .foregroundStyle(Design.Color.subtle)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private func copyGroup(title: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Color.glassFill, in: RoundedRectangle(cornerRadius: Design.Radius.card))
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "low": "Likely low"
        case "high": "Above limit"
        case "on_track": "On track"
        default: "Uncertain"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "low": Design.Color.warning
        case "high": Design.Color.danger
        case "on_track": Design.Color.success
        default: Design.Color.muted
        }
    }

    private func amountText(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
