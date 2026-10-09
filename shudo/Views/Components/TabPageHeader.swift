import SwiftUI

/// The top of a tab: a serif title set left, one quiet line under it, and at
/// most one small control on the right. Today, Body and Train open the same
/// way, so moving between tabs never re-learns where things are. (Today's
/// own title row in `DayHeader` uses these exact metrics, plus its day
/// picker.)
struct TabPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// Pernambuco subtitle for a live state ("typing…"); oak-grey otherwise.
    var subtitleIsLive = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Design.Typeface.display(.title2))
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Design.Typeface.text(.caption))
                        .foregroundStyle(subtitleIsLive ? Design.Color.ember : Design.Color.textTertiary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: 44)
        .padding(.horizontal, Design.Space.gutter)
        .padding(.top, Design.Space.xs)
        .padding(.bottom, Design.Space.s)
    }
}

extension TabPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The small round control a tab header may carry on its right — the same
/// 30 pt walnut seal as Today's account button, in a 44 pt target.
struct HeaderSealButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Design.Typeface.text(.footnote, weight: .medium))
                .foregroundStyle(isOn ? Design.Color.textPrimary : Design.Color.textSecondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Design.Color.surface2, in: Circle())
                .overlay(Circle().stroke(Design.Color.hairline, lineWidth: Design.Stroke.hairline))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
