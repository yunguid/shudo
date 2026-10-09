import SwiftUI

/// Two check-ins against each other: one frame with a draggable wipe
/// between "before" and "after" (or side by side, from the toolbar).
/// Defaults to the first photo vs the latest; a thumbnail strip re-picks
/// either side.
struct PhysiqueCompareView: View {
    enum Mode { case wipe, sideBySide }

    enum Side { case before, after }

    /// Photo check-ins (any order).
    let checkIns: [WeightCheckIn]
    let units: String
    let trendPoints: [WeightTrendPoint]
    @ObservedObject var loader: BodyPhotoLoader

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sideNamespace
    @State private var mode: Mode = .wipe
    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var picking: Side = .before
    @State private var wipe: CGFloat = 0.5

    init(
        checkIns: [WeightCheckIn],
        units: String,
        loader: BodyPhotoLoader,
        trendPoints: [WeightTrendPoint] = [],
        before: WeightCheckIn? = nil
    ) {
        let ordered = checkIns.filter(\.hasPhoto).sorted { $0.localDay < $1.localDay }
        self.checkIns = ordered
        self.units = units
        self.trendPoints = trendPoints
        self.loader = loader
        _beforeID = State(initialValue: (before ?? ordered.first)?.id)
        _afterID = State(initialValue: ordered.last?.id)
    }

    private var before: WeightCheckIn? { checkIns.first { $0.id == beforeID } }
    private var after: WeightCheckIn? { checkIns.first { $0.id == afterID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: Design.Space.xl) {
                ZStack {
                    switch mode {
                    case .wipe: wipeView.transition(.ink(reduceMotion: reduceMotion))
                    case .sideBySide: sideBySide.transition(.ink(reduceMotion: reduceMotion))
                    }
                }
                .padding(.horizontal, Design.Space.l)

                summary
                picker
                Spacer(minLength: 0)
            }
            .padding(.top, Design.Space.s)
            .background(AppBackground())
            .blur(radius: scenePhase == .active ? 0 : 30)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion)) {
                            mode = mode == .wipe ? .sideBySide : .wipe
                        }
                    } label: {
                        Image(systemName: mode == .wipe ? "square.split.2x1" : "rectangle.split.2x1")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(mode == .wipe ? "Show side by side" : "Show wipe")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Modes

    private var wipeView: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                photo(after, maxPixel: BodyPhotoSize.full)
                photo(before, maxPixel: BodyPhotoSize.full)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * wipe)
                    }
                // The seam: a hinoki hairline and a small glass knob on it.
                Rectangle()
                    .fill(Design.Color.hinoki.opacity(0.9))
                    .frame(width: 1.5)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .offset(x: width * wipe - 0.75)
                Image(systemName: "arrow.left.and.right")
                    .font(Design.Typeface.text(.caption, weight: .semibold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .frame(width: 34, height: 34)
                    .chromeGlass(in: Circle(), tint: Design.Color.canvas.opacity(0.35))
                    .offset(x: width * wipe - 17)
            }
            .overlay(alignment: .topLeading) { cornerLabel(before).padding(10) }
            .overlay(alignment: .topTrailing) { cornerLabel(after).padding(10) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in wipe = min(max(value.location.x / max(width, 1), 0.02), 0.98) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Before and after wipe")
            .accessibilityValue("\(Int(wipe * 100)) percent before")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: wipe = min(wipe + 0.1, 0.98)
                case .decrement: wipe = max(wipe - 0.1, 0.02)
                @unknown default: break
                }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
    }

    private var sideBySide: some View {
        HStack(spacing: 8) {
            ForEach([("Before", before), ("After", after)], id: \.0) { _, checkIn in
                Color.clear
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay { photo(checkIn, maxPixel: BodyPhotoSize.hero) }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) { cornerLabel(checkIn).padding(8) }
            }
        }
    }

    private func photo(_ checkIn: WeightCheckIn?, maxPixel: Int) -> some View {
        BodyPhotoImage(path: checkIn?.progressPhotoPath, loader: loader, maxPixel: maxPixel)
    }

    @ViewBuilder
    private func cornerLabel(_ checkIn: WeightCheckIn?) -> some View {
        if let checkIn {
            Text(BodyDayLabel.short(checkIn.localDay))
                .font(Design.Typeface.numeral(.caption, weight: .medium))
                .foregroundStyle(Design.Color.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .chromeGlass(in: Capsule(), tint: Design.Color.canvas.opacity(0.5))
        }
    }

    // MARK: Summary + picker

    /// "11 days · +1.2 lb": the gap, and the change when either the scale
    /// or the trend knows both ends.
    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xl) {
            if let before, let after {
                let days = abs(LocalDayMath.days(from: before.localDay, to: after.localDay) ?? 0)
                stat("\(days)", caption: days == 1 ? "day apart" : "days apart")
                if let change = weightChange(before, after) {
                    stat(BodyUnits.signed(BodyUnits.display(change, units: units)), caption: BodyUnits.label(units))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.gutter)
        .contentTransition(.numericText())
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: beforeID)
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: afterID)
    }

    private func weightChange(_ before: WeightCheckIn, _ after: WeightCheckIn) -> Double? {
        if let start = before.weightKG, let end = after.weightKG { return end - start }
        if let start = trendNear(before.localDay), let end = trendNear(after.localDay) { return end - start }
        return nil
    }

    /// The trend weight from a weigh-in within 3 days of `day`, if any.
    private func trendNear(_ day: String) -> Double? {
        trendPoints
            .compactMap { point -> (gap: Int, trend: Double)? in
                guard let gap = LocalDayMath.days(from: point.localDay, to: day), abs(gap) <= 3 else { return nil }
                return (abs(gap), point.trend)
            }
            .min { $0.gap < $1.gap }?
            .trend
    }

    private func stat(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            Text(value)
                .font(Design.Typeface.figure(.title2))
                .foregroundStyle(Design.Color.textPrimary)
            Text(caption)
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.textTertiary)
        }
    }

    /// Which side you're choosing (two quiet words on a sliding walnut step),
    /// then the log to choose from; the chosen photo wears a Pernambuco ring.
    private var picker: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack(spacing: Design.Space.xxs) {
                sideChip("Before", side: .before)
                sideChip("After", side: .after)
                Spacer()
            }
            .padding(.horizontal, Design.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Design.Space.s) {
                    ForEach(checkIns) { checkIn in
                        let selected = checkIn.id == (picking == .before ? beforeID : afterID)
                        Button {
                            withAnimation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion)) {
                                if picking == .before { beforeID = checkIn.id } else { afterID = checkIn.id }
                            }
                        } label: {
                            VStack(spacing: Design.Space.xs) {
                                Color.clear
                                    .frame(width: 52, height: 69)
                                    .overlay { photo(checkIn, maxPixel: BodyPhotoSize.thumb) }
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .padding(2.5)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(selected ? Design.Color.pernambuco : .clear, lineWidth: 1.25)
                                    }
                                Text(BodyDayLabel.short(checkIn.localDay))
                                    .font(BodyType.fixed(9.5))
                                    .foregroundStyle(selected ? Design.Color.textSecondary : Design.Color.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(picking == .before ? "Before" : "After"): \(BodyDayLabel.short(checkIn.localDay))")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Design.Space.l - 2.5)
            }
            .frame(height: 94)
        }
    }

    private func sideChip(_ title: String, side: Side) -> some View {
        let selected = picking == side
        return Button {
            withAnimation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion)) {
                picking = side
            }
        } label: {
            Text(title)
                .font(Design.Typeface.text(.footnote, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Design.Color.textPrimary : Design.Color.textTertiary)
                .padding(.horizontal, Design.Space.m)
                .frame(height: 30)
                .background {
                    if selected {
                        Capsule()
                            .fill(Design.Color.surface3)
                            .matchedGeometryEffect(id: "side", in: sideNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Full-screen pager through the physique log, newest first.
struct PhysiquePhotoViewer: View {
    let checkIns: [WeightCheckIn]
    let units: String
    let timezone: String
    @ObservedObject var loader: BodyPhotoLoader
    @State var selection: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(checkIns) { checkIn in
                    VStack(alignment: .leading, spacing: 12) {
                        Color.clear
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .overlay { BodyPhotoImage(path: checkIn.progressPhotoPath, loader: loader, maxPixel: BodyPhotoSize.full) }
                            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
                        details(checkIn)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .tag(checkIn.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(AppBackground())
            .blur(radius: scenePhase == .active ? 0 : 30)
            .navigationTitle(checkIns.first { $0.id == selection }.map { BodyDayLabel.short($0.localDay) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func details(_ checkIn: WeightCheckIn) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                if let weight = checkIn.weightKG {
                    Text("\(BodyUnits.format(BodyUnits.display(weight, units: units))) \(BodyUnits.label(units))")
                        .font(Design.Typeface.figure(.title2))
                        .foregroundStyle(Design.Color.textPrimary)
                }
                if let captured = checkIn.photoCapturedAt {
                    Text(BodyDayLabel.time(captured, timezone: timezone))
                        .font(Design.Typeface.text(.footnote))
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            if let note = checkIn.note {
                Text(note).font(Design.Typeface.text(.subheadline)).foregroundStyle(Design.Color.textSecondary)
            }
            if let review = checkIn.coachReview, let headline = review.headline ?? review.coachNote {
                Label {
                    Text(headline).font(Design.Typeface.text(.subheadline)).foregroundStyle(Design.Color.textPrimary)
                } icon: {
                    CoachAvatar(size: 20)
                }
            }
        }
    }
}
