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

/// A section heading, set like the Bio page's: small, in oak, sentence case.
struct SettingsSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typeface.display(.title3))
            .foregroundStyle(Design.Color.textSecondary)
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
                .font(Design.Typeface.text(.body))
                .foregroundStyle(Design.Color.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Design.Typeface.text(.footnote))
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

/// A menu picker whose closed state is set in the app's typeface: the
/// current value in oak and a small up-down mark. (A plain `.menu` Picker
/// draws its label in the system font.)
struct SettingsMenuPicker<Option: Hashable>: View {
    let label: String
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(selection))
                    .font(Design.Typeface.text(.body))
                    .foregroundStyle(Design.Color.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Design.Typeface.text(.caption, weight: .semibold))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
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
                .font(Design.Typeface.text(.caption, weight: .semibold))
                .foregroundStyle(Design.Color.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Design.Space.m)
        .frame(minHeight: SettingsStyle.rowHeight)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(title)
            .font(Design.Typeface.text(.body))
            .foregroundStyle(Design.Color.textPrimary)
    }

    @ViewBuilder
    private var valueText: some View {
        if let value {
            Text(value)
                .font(Design.Typeface.text(.body))
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

/// A placeholder breathing slowly (opacity only), calmer than a sweeping
/// shimmer.
private struct SlowBreath: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content.opacity(0.55 + 0.45 * (1 + cos(t * 2 * .pi / 2.8)) / 2)
        }
    }
}

extension View {
    /// Content that settles in as its sheet or flow appears.
    func settlesOnAppear() -> some View { modifier(SettleOnAppear()) }

    /// A loading placeholder that breathes slowly.
    func breathesSlowly() -> some View { modifier(SlowBreath()) }

    /// A bottom bar's ground: solid canvas behind the controls, with a short
    /// fixed fade above so scrolling text dissolves before it reaches them
    /// (never half-visible beside a button).
    func bottomBarGround(fade: CGFloat = 28) -> some View {
        background {
            Design.Color.canvas
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Design.Color.canvas.opacity(0), Design.Color.canvas],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: fade)
                    .offset(y: -fade)
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
        }
    }
}

extension AnyTransition {
    /// One panel giving way to another, like shoji doors: the outgoing one
    /// slides a little toward its edge and is gone quickly; the incoming one
    /// waits a beat, then slides home. Never a half-and-half blend of both.
    /// Under Reduce Motion: the same hand-off as plain fades.
    static func shojiPage(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.12)),
                removal: .opacity.animation(.easeIn(duration: 0.12))
            )
        }
        return .asymmetric(
            insertion: .shoji(edge, reduceMotion: false).animation(Design.Motion.shoji.delay(0.14)),
            removal: .shoji(edge, reduceMotion: false).animation(.easeIn(duration: 0.16))
        )
    }

    /// One control giving way to another in the same place (a slab and a
    /// text field): the old one is gone quickly, the new one settles in like
    /// ink a beat later.
    static func inkHandoff(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .ink(reduceMotion: reduceMotion)
                .animation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion).delay(0.12)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }
}
