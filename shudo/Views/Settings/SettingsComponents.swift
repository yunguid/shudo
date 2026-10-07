import SwiftUI

/// One inset group in Settings: an optional small label, then rows on a
/// single surface with hairlines between them.
struct SettingsGroup<Content: View, Accessory: View>: View {
    let label: String?
    let accessory: () -> Accessory
    let content: () -> Content

    init(
        label: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.label = label
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                HStack(alignment: .firstTextBaseline) {
                    SettingsSectionLabel(text: label)
                    Spacer(minLength: 8)
                    accessory()
                }
                .padding(.horizontal, 16)
            }
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { HairlineRule().padding(.leading, 16) }
                        row
                    }
                }
            }
            .background(
                Design.Color.surface1,
                in: RoundedRectangle(cornerRadius: Design.Radius.xl, style: .continuous)
            )
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(label: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(label: label, content: content, accessory: { EmptyView() })
    }
}

struct SettingsSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Design.Color.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Title (and an optional quiet subtitle) on the left, anything on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = Design.Color.textTertiary
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Accessibility sizes stack the control under its title instead of
        // squeezing both onto one line.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Design.Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !stacked { Spacer(minLength: 8) }
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// A row that navigates or opens something: title, quiet value, chevron.
struct SettingsValueLabel: View {
    let title: String
    var value: String?
    var valueColor: Color = Design.Color.textSecondary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    titleText
                    valueText
                }
                Spacer(minLength: 8)
            } else {
                titleText
                Spacer(minLength: 8)
                valueText
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Design.Color.textPrimary)
    }

    @ViewBuilder
    private var valueText: some View {
        if let value {
            Text(value)
                .font(.body)
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}
