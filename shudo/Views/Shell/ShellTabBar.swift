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
        /// An SF Symbol; nil draws Train's own mark.
        let symbol: String?
    }

    private static let items: [Item] = [
        Item(tab: .today, title: "Today", symbol: "bubble.left.and.text.bubble.right"),
        Item(tab: .body, title: "Body", symbol: "figure.arms.open"),
        Item(tab: .train, title: "Train", symbol: nil),
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
                glyph(item, selected: selected)
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
            // The viewer shows an SF Symbol; "stairs" is Train's mark's nearest.
            Label(item.title, systemImage: item.symbol ?? "stairs")
        }
    }

    // Outline at rest, filled when chosen.
    @ViewBuilder
    private func glyph(_ item: Item, selected: Bool) -> some View {
        if let symbol = item.symbol {
            Image(systemName: symbol)
                .font(.custom(Design.Typeface.faceName(.medium), fixedSize: 17))
                .fontWeight(.medium)
                .symbolVariant(selected ? .fill : .none)
        } else {
            TrainStepsMark(filled: selected)
        }
    }
}

/// Train's mark: three steps rising — the climb a session at a time — drawn
/// rather than borrowed, since the SF dumbbell read as clip art. Weighted
/// and sized to sit with the SF glyphs beside it, and it fills the same way.
struct TrainStepsMark: View {
    var filled = false

    private static let lineWidth: CGFloat = 1.8

    var body: some View {
        ZStack {
            if filled { StepsShape().fill() }
            StepsShape().stroke(style: StrokeStyle(lineWidth: Self.lineWidth, lineJoin: .round))
        }
        // The stroke straddles the path; inset it so the mark's outer edge
        // is the frame.
        .padding(Self.lineWidth / 2)
        .frame(width: 18, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Train")
    }

    /// Three equal steps rising left to right, as one closed outline.
    private struct StepsShape: Shape {
        func path(in rect: CGRect) -> Path {
            let run = rect.width / 3
            let rise = rect.height / 3
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for step in 0..<3 {
                let x = rect.minX + CGFloat(step) * run
                let y = rect.maxY - CGFloat(step + 1) * rise
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + run, y: y))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
