import SwiftUI

/// Shared look for Settings and its sheets.
enum SettingsStyle {
    /// Toggles glow heartwood, not full Pernambuco: a column of switches
    /// should read "on" without shouting.
    static let toggleTint = Design.Color.heartwood
    /// Row height: generous enough to breathe, the same everywhere.
    static let rowHeight: CGFloat = 56
}

/// One group in Settings: rows straight on the wood, a hairline between
/// them, an optional quiet label above. Groups are separated by ma (the
/// parent's spacing), never by boxes.
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
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            if let label {
                HStack(alignment: .firstTextBaseline) {
                    SettingsSectionLabel(text: label)
                    Spacer(minLength: 8)
                    accessory()
                }
            }
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { HairlineRule() }
                        row
                    }
                }
            }
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
            .eyebrowStyle()
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
            SettingsRowTitle(title: title, subtitle: subtitle, subtitleColor: subtitleColor)
            if !stacked { Spacer(minLength: 8) }
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Design.Space.m)
        .frame(minHeight: SettingsStyle.rowHeight)
        .contentShape(Rectangle())
    }
}

/// A row's title and optional quiet subtitle.
struct SettingsRowTitle: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = Design.Color.textTertiary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
    }
}

/// A toggle row: title (and subtitle) left, the switch right.
struct SettingsToggleRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: () -> Label

    var body: some View {
        Toggle(isOn: $isOn, label: label)
            .tint(SettingsStyle.toggleTint)
            .padding(.vertical, Design.Space.s)
            .frame(minHeight: SettingsStyle.rowHeight)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Design.Space.m)
        .frame(minHeight: SettingsStyle.rowHeight)
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

/// A sheet's or flow's content arriving: it rises a few points and clears
/// as the sheet slides home, so the whole thing lands with weight instead of
/// appearing pre-painted. A plain fade under Reduce Motion.
private struct SettleOnAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .opacity(settled ? 1 : 0)
            .offset(y: settled || reduceMotion ? 0 : 16)
            .onAppear {
                withAnimation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion)) {
                    settled = true
                }
            }
    }
}

extension View {
    /// Content that settles in as its sheet or flow appears.
    func settlesOnAppear() -> some View { modifier(SettleOnAppear()) }
}
