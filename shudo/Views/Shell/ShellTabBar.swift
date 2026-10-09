import SwiftUI

/// Today · Body · Train, beside the well. A hinoki-tinted glass track; the
/// chosen tab carries a soft lens that slides to it, its icon in Pernambuco.
/// The system tab bar is hidden — this one lives in the command band so it
/// can sit beside the well instead of across the corner.
struct ShellTabBar: View {
    @Binding var tab: AppTab
    var todayBadge: Int = 0

    @Namespace private var lens
    /// Where the lens rests; follows `tab` on its own spring, since the
    /// shell switches tabs in a transaction with animations off.
    @State private var lensTab: AppTab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Item {
        let tab: AppTab
        let title: String
        let symbol: String
    }

    private static let items: [Item] = [
        Item(tab: .today, title: "Today", symbol: "bubble.left.and.text.bubble.right"),
        Item(tab: .body, title: "Body", symbol: "figure.arms.open"),
        Item(tab: .train, title: "Train", symbol: "dumbbell"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items, id: \.tab) { item in
                button(item)
            }
        }
        .padding(4)
        // The lens slides to the chosen tab; the screens hand off in the shell.
        .onAppear { lensTab = tab }
        .onChange(of: tab) { _, new in
            withAnimation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion)) { lensTab = new }
        }
        .frame(height: CommandBandMetrics.barHeight)
        // A flat walnut track: the well's rim is the band's one metal edge.
        .background(Design.Color.surface1, in: Capsule())
        // Like the system tab bar: labels stay put at large sizes and the
        // large content viewer shows them instead.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func button(_ item: Item) -> some View {
        let selected = (lensTab ?? tab) == item.tab
        return Button {
            guard tab != item.tab else { return }
            // The lens moves with the finger; the screens hand off in the shell.
            withAnimation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion)) { lensTab = item.tab }
            tab = item.tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.custom(Design.Typeface.faceName(.medium), fixedSize: 17))
                    .fontWeight(.medium)
                    // Outline at rest, filled when chosen.
                    .symbolVariant(selected ? .fill : .none)
                    .frame(height: 21)
                    .foregroundStyle(selected ? Design.Color.pernambuco : Design.Color.textSecondary)
                    .overlay(alignment: .topTrailing) {
                        if item.tab == .today, todayBadge > 0, !selected {
                            Circle()
                                .fill(Design.Color.pernambuco)
                                .frame(width: 8, height: 8)
                                .offset(x: 6, y: -1)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                Text(item.title)
                    .font(Design.Typeface.text(.caption2, weight: .semibold))
                    .foregroundStyle(selected ? Design.Color.textPrimary : Design.Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    Capsule()
                        .fill(Design.Color.hinoki.opacity(0.08))
                        .matchedGeometryEffect(id: "lens", in: lens)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.tab == .today && todayBadge > 0 ? "\(todayBadge) new" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(item.tab.rawValue)")
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.symbol)
        }
    }
}
