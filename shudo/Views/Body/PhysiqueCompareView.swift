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
            VStack(spacing: 14) {
                Group {
                    switch mode {
                    case .wipe: wipeView
                    case .sideBySide: sideBySide
                    }
                }
                .padding(.horizontal, 16)

                summary
                picker
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .background(Design.Color.canvas.ignoresSafeArea())
            .blur(radius: scenePhase == .active ? 0 : 30)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        mode = mode == .wipe ? .sideBySide : .wipe
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
                Rectangle()
                    .fill(Design.Color.cream)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: width * wipe - 1)
                Image(systemName: "arrow.left.and.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Design.Color.onEmber)
                    .frame(width: 36, height: 36)
                    .background(Design.Color.emberFill, in: Circle())
                    .shadow(color: .black.opacity(0.35), radius: 6)
                    .offset(x: width * wipe - 18)
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
                .font(Design.Typeface.numeral(.caption, weight: .bold))
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
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let before, let after {
                let days = abs(LocalDayMath.days(from: before.localDay, to: after.localDay) ?? 0)
                stat("\(days)", caption: days == 1 ? "day" : "days")
                if let change = weightChange(before, after) {
                    stat(BodyUnits.signed(BodyUnits.display(change, units: units)), caption: BodyUnits.label(units))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
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
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Design.Typeface.numeral(.title2, weight: .bold))
                .foregroundStyle(Design.Color.textPrimary)
                .monospacedDigit()
            Text(caption).font(Design.Typeface.meta).foregroundStyle(Design.Color.textTertiary)
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sideChip("Before", side: .before)
                sideChip("After", side: .after)
                Spacer()
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(checkIns) { checkIn in
                        let selected = checkIn.id == (picking == .before ? beforeID : afterID)
                        Button {
                            if picking == .before { beforeID = checkIn.id } else { afterID = checkIn.id }
                        } label: {
                            Color.clear
                                .frame(width: 54, height: 72)
                                .overlay { photo(checkIn, maxPixel: BodyPhotoSize.thumb) }
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(selected ? Design.Color.ember : Design.Color.hairline, lineWidth: selected ? 2 : 0.5)
                                }
                                .overlay(alignment: .bottom) {
                                    Text(BodyDayLabel.short(checkIn.localDay))
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(Design.Color.textPrimary)
                                        .padding(.bottom, 3)
                                        .shadow(color: .black.opacity(0.6), radius: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(picking == .before ? "Before" : "After"): \(BodyDayLabel.short(checkIn.localDay))")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 76)
        }
        .sensoryFeedback(.selection, trigger: beforeID)
        .sensoryFeedback(.selection, trigger: afterID)
    }

    private func sideChip(_ title: String, side: Side) -> some View {
        Button {
            picking = side
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(picking == side ? Design.Color.onEmber : Design.Color.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(picking == side ? AnyShapeStyle(Design.Color.ember) : AnyShapeStyle(Design.Color.surface3), in: Capsule())
        }
        .buttonStyle(.plain)
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
            .background(Design.Color.canvas.ignoresSafeArea())
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let weight = checkIn.weightKG {
                    Text("\(BodyUnits.format(BodyUnits.display(weight, units: units))) \(BodyUnits.label(units))")
                        .font(Design.Typeface.numeral(.title3, weight: .bold))
                        .foregroundStyle(Design.Color.textPrimary)
                }
                if let captured = checkIn.photoCapturedAt {
                    Text(BodyDayLabel.time(captured, timezone: timezone))
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            if let note = checkIn.note {
                Text(note).font(.subheadline).foregroundStyle(Design.Color.textSecondary)
            }
            if let review = checkIn.coachReview, let headline = review.headline ?? review.coachNote {
                Label {
                    Text(headline).font(.subheadline).foregroundStyle(Design.Color.textPrimary)
                } icon: {
                    CoachAvatar(size: 20)
                }
            }
        }
    }
}
