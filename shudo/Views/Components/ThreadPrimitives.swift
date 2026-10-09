import SwiftUI
import UIKit

// MARK: - Coach avatar: the app icon's 3x3 pad grid, drawn in SwiftUI.
// Rows go amber → honey → cream like the icon. While Shudo is "thinking",
// the pads light like a step sequencer (the typing indicator *is* his face).

struct CoachAvatar: View {
    var size: CGFloat = 30
    var isThinking = false
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
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(hex: 0x2A2118), Color(hex: 0x120F0C)],
                        center: .init(x: 0.5, y: 0.35), startRadius: 0, endRadius: size * 0.7))
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
            .overlay(Circle().stroke(Design.Color.hairline, lineWidth: 0.5))
        }
        .accessibilityHidden(true)
    }
}

/// Typing indicator: three pads in a coach bubble, stepping like a sequencer.
struct CoachTypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PhaseAnimator([0, 1, 2]) { phase in
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Design.Color.ember)
                        .frame(width: 9, height: 9)
                        .opacity(reduceMotion ? 0.7 : (i == phase ? 1 : 0.28))
                        .scaleEffect(reduceMotion ? 1 : (i == phase ? 1.12 : 0.9))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Design.Color.bubbleCoach, in: BubbleShape(isMine: false, position: .single))
        } animation: { _ in .snappy(duration: 0.22) }
        .accessibilityLabel("Shudo is typing")
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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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

/// Centered stamp between the day's chapters: "7:21 PM", or with the day
/// on the first one ("**Today** 6:52 AM"), like Messages.
struct ThreadTimestamp: View {
    var day: String?
    let time: String

    var body: some View {
        Group {
            if let day {
                Text("\(Text(day).fontWeight(.semibold)) \(time)")
            } else {
                Text(time)
            }
        }
        .font(Design.Typeface.meta)
        .foregroundStyle(Design.Color.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 8)
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

/// Two concentric rings: calories (cream, outer) and protein (ember, inner).
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
            Circle().stroke(color.opacity(0.16), lineWidth: width)
            RingArc(progress: progress)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .shadow(color: color.opacity(progress >= 1 ? 0.6 : 0), radius: 6)
        }
        .padding(inset)
    }
}

struct MacroBar: View {
    let label: String
    let value: Double
    let target: Double
    let color: Color

    @ScaledMetric(relativeTo: .caption) private var valueWidth: CGFloat = 62

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Design.Typeface.eyebrow)
                .foregroundStyle(color)
                .fixedSize()
                .frame(minWidth: 12, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(color.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: value > 0 ? max(5, geo.size.width * min(value / target, 1)) : 0)
                    }
            }
            .frame(height: 5)
            HStack(spacing: 0) {
                Text("\(Int(value))").foregroundStyle(Design.Color.textPrimary)
                Text("/\(Int(target))").foregroundStyle(Design.Color.textTertiary)
            }
            .font(Design.Typeface.numeral(.caption, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: valueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value)) of \(Int(target)) grams")
    }
}

struct MacroInline: View {
    let p: Double, c: Double, f: Double
    var body: some View {
        HStack(spacing: 8) {
            item(p, "P", Design.Color.macroProtein)
            item(c, "C", Design.Color.macroCarbs)
            item(f, "F", Design.Color.macroFat)
        }
        .font(Design.Typeface.numeral(.caption, weight: .semibold))
        .monospacedDigit()
    }
    private func item(_ value: Double, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(Int(value))").foregroundStyle(Design.Color.textPrimary)
            Text(label).foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
