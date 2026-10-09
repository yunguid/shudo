import SwiftUI
import UIKit

// MARK: - Coach avatar: the app icon's 3x3 pad grid, drawn in SwiftUI.
// Rows go amber → honey → cream like the icon. While Shudo is "thinking",
// the pads light like a step sequencer (the typing indicator *is* his face).

struct CoachAvatar: View {
    var size: CGFloat = 30
    var isThinking = false
    /// False draws just the pads, for a surface that brings its own (the
    /// command key's walnut slab).
    var showsDisc = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rowColors: [Color] = [
        Color(hex: 0xDE9D43), Color(hex: 0xFAD597), Color(hex: 0xF9E4CA)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: !isThinking || reduceMotion)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 6) % 9
            let pad = size * 0.2
            let gap = size * 0.06
            ZStack {
                if showsDisc {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(hex: 0x2A2118), Color(hex: 0x120F0C)],
                            center: .init(x: 0.5, y: 0.35), startRadius: 0, endRadius: size * 0.7))
                }
                VStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<3, id: \.self) { col in
                                let index = row * 3 + col
                                RoundedRectangle(cornerRadius: pad * 0.24, style: .continuous)
                                    .fill(Self.rowColors[row])
                                    .frame(width: pad, height: pad)
                                    .opacity(isThinking && !reduceMotion ? (index == step ? 1 : 0.35) : 1)
                                    .shadow(color: Self.rowColors[row].opacity(0.55), radius: size * 0.04)
                            }
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .overlay {
                if showsDisc { Circle().stroke(Design.Color.hairline, lineWidth: 0.5) }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Typing indicator: three small pads in a coach bubble, breathing one
/// after another — slow enough to read as thought, not as a spinner. No
/// words under it, ever.
struct CoachTypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                pads(lit: nil)
            } else {
                PhaseAnimator([0, 1, 2]) { phase in
                    pads(lit: phase)
                } animation: { _ in .easeInOut(duration: 0.42) }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .background(Design.Color.bubbleCoach, in: BubbleShape(isMine: false, position: .single))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shudo is typing")
    }

    private func pads(lit: Int?) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Design.Color.ember)
                    .frame(width: 7, height: 7)
                    .opacity(lit.map { $0 == index ? 0.95 : 0.3 } ?? 0.6)
            }
        }
    }
}

// MARK: - Bubbles

enum BubblePosition { case single, first, middle, last }

struct BubbleShape: Shape {
    let isMine: Bool
    let position: BubblePosition

    func path(in rect: CGRect) -> Path {
        let big = Design.Radius.bubble
        let tail = Design.Radius.tail
        let tightTop = position == .middle || position == .last
        let tightBottom = position == .first || position == .middle
        let radii = RectangleCornerRadii(
            topLeading: !isMine && tightTop ? tail : big,
            bottomLeading: !isMine && tightBottom ? tail : big,
            bottomTrailing: isMine && tightBottom ? tail : big,
            topTrailing: isMine && tightTop ? tail : big
        )
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
    }
}

struct MessageBubble: View {
    let text: String
    let isMine: Bool
    var position: BubblePosition = .single
    @State private var isSelectingText = false

    var body: some View {
        Text(text)
            .font(Design.Typeface.bubble)
            .foregroundStyle(isMine ? Design.Color.onBubbleMe : Design.Color.textPrimary)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background {
                if isMine {
                    BubbleShape(isMine: true, position: position).fill(Design.Color.bubbleMe)
                } else {
                    BubbleShape(isMine: false, position: position).fill(Design.Color.bubbleCoach)
                }
            }
            // Long-press lifts just the bubble (Messages-style) with copy actions.
            .contentShape(.contextMenuPreview, BubbleShape(isMine: isMine, position: position))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    isSelectingText = true
                } label: {
                    Label("Select Text", systemImage: "selection.pin.in.out")
                }
                ShareLink(item: text) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
            .sheet(isPresented: $isSelectingText) {
                MessageTextSelectionSheet(text: text)
            }
            .frame(maxWidth: 290, alignment: isMine ? .trailing : .leading)
    }
}

/// Full message text with native selection, for copying part of a bubble.
private struct MessageTextSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(Design.Typeface.bubble)
                    .foregroundStyle(Design.Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Design.Space.gutter)
            }
            .background(Design.Color.canvas)
            .navigationTitle("Select Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy All") {
                        UIPasteboard.general.string = text
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Shudo's side of the thread. A one-to-one conversation needs no avatar
/// gutter (the title already says who this is), so his column starts at
/// the margin like Messages.
struct CoachRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            content
            Spacer(minLength: 48)
        }
    }
}

struct MeRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack {
            Spacer(minLength: 64)
            content
        }
    }
}

/// Centered stamp between the day's chapters: just the time ("7:21 PM") —
/// the header above already names the day. It brings the pause above it,
/// the ma that says a new part of the day begins.
struct ThreadTimestamp: View {
    let time: String

    var body: some View {
        Text(time)
            .font(Design.Typeface.text(.caption2))
            .monospacedDigit()
            .foregroundStyle(Design.Color.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
            .padding(.bottom, 10)
    }
}

// MARK: - Macro primitives

struct RingArc: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * min(max(progress, 0), 1)),
            clockwise: false
        )
        return path
    }
}

/// Two concentric rings: calories (hinoki, outer) and protein (Pernambuco,
/// inner). A met target is simply a closed ring — no glow.
struct MacroRings: View {
    let kcal: Double
    let protein: Double
    var size: CGFloat = 56
    var lineWidth: CGFloat? = nil

    var body: some View {
        let width = lineWidth ?? size * 0.12
        let gap = width * 0.45
        ZStack {
            ring(progress: kcal, color: Design.Color.macroKcal, inset: width / 2, width: width)
            ring(progress: protein, color: Design.Color.macroProtein, inset: width * 1.5 + gap, width: width)
        }
        .frame(width: size, height: size)
    }

    private func ring(progress: Double, color: Color, inset: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.13), lineWidth: width)
            RingArc(progress: progress)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        .padding(inset)
    }
}

/// One labelled line of the day's breakdown: "Protein ━━━━ 179 / 175 g".
struct MacroBar: View {
    let label: String
    let value: Double
    let target: Double
    let color: Color

    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .caption) private var valueWidth: CGFloat = 76
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Large text: words and numbers on one line, the stroke
                // full width beneath, so the bar never shrinks to a dash.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        name
                        Spacer(minLength: Design.Space.s)
                        amount
                    }
                    stroke
                }
            } else {
                HStack(spacing: Design.Space.m) {
                    name.frame(minWidth: labelWidth, alignment: .leading)
                    stroke
                    amount.frame(minWidth: valueWidth, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value.rounded())) of \(Int(target.rounded())) grams")
    }

    private var name: some View {
        Text(label)
            .font(Design.Typeface.text(.footnote))
            .foregroundStyle(Design.Color.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var stroke: some View {
        DayStroke(progress: min(value / target, 1), color: color)
    }

    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(Int(value.rounded()))").foregroundStyle(Design.Color.textPrimary)
            Text(" / \(Int(target.rounded())) g").foregroundStyle(Design.Color.textTertiary)
        }
        .font(Design.Typeface.numeral(.caption))
        .lineLimit(1)
        .fixedSize()
    }
}

/// "58 P  72 C  19 F" under a meal: protein carries the accent, carbs and
/// fat recede into their pigments.
struct MacroInline: View {
    let p: Double, c: Double, f: Double
    var body: some View {
        HStack(spacing: 9) {
            item(p, "P", value: Design.Color.textPrimary, letter: Design.Color.macroProtein)
            item(c, "C", value: Design.Color.textSecondary, letter: Design.Color.macroCarbs)
            item(f, "F", value: Design.Color.textSecondary, letter: Design.Color.macroFat)
        }
        .font(Design.Typeface.numeral(.caption))
        .monospacedDigit()
    }
    private func item(_ amount: Double, _ label: String, value: Color, letter: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(Int(amount.rounded()))").foregroundStyle(value)
            Text(label).foregroundStyle(letter)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
