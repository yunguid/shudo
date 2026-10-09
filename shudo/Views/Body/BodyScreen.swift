import SwiftUI

/// The Body tab, read top to bottom like a quiet page: where the bulk is
/// (the trend weight as the one serif figure, the barbell for how much is
/// loaded, the trend line beneath), today's check-in as a single line, the
/// physique log with its privacy veil and compare, the Fuel calendar, and
/// the weekly recaps as a ledger. Regions are grouped by space, not boxes.
/// Owns its NavigationStack; mount it directly in a tab.
struct BodyScreen: View {
    @StateObject private var model: BodyViewModel
    private let onCheckInSaved: (WeightCheckIn) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 64
    @Namespace private var zoom
    @State private var revealed: Bool
    @State private var showsCamera = false
    @State private var showsWeightEntry = false
    @State private var compare: CompareRequest?
    @State private var viewer: ViewerRequest?
    @State private var pendingDelete: WeightCheckIn?
    @State private var previewAction: BodyPreviewAction?
    @State private var presentsLatestRecap = false
    /// One-shot scroll on appear (deep links / preview screenshots).
    @State private var scrollTarget: BodySection?
    #if DEBUG
        @State private var previewReviewImage: UIImage?
    #endif

    /// - Parameters:
    ///   - profile: the signed-in profile (units, timezone, targets, goal).
    ///   - onCheckInSaved: called after every saved check-in (photo and/or
    ///     weight) so the shell can run `coach_sync(trigger: "checkin")`.
    init(
        profile: Profile,
        service: any BodyServicing = LiveBodyService(),
        onCheckInSaved: @escaping (WeightCheckIn) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: BodyViewModel(profile: profile, service: service))
        self.onCheckInSaved = onCheckInSaved
        _revealed = State(initialValue: false)
        _previewAction = State(initialValue: nil)
    }

    #if DEBUG
        init(
            previewModel: BodyViewModel,
            previewAction: BodyPreviewAction? = nil,
            revealed: Bool = false,
            scrollTo section: BodySection? = nil
        ) {
            _model = StateObject(wrappedValue: previewModel)
            onCheckInSaved = { _ in }
            _revealed = State(initialValue: revealed)
            _previewAction = State(initialValue: previewAction)
            _scrollTarget = State(initialValue: section)
        }
    #endif

    private var snapshot: BodySnapshot { model.snapshot }
    private var units: String { model.units }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.section) {
                        if let message = model.errorMessage {
                            errorBanner(message)
                        }
                        hero.id(BodySection.weight)
                        checkInLine.id(BodySection.hero)
                        if !snapshot.photoCheckIns.isEmpty {
                            physiqueStrip.id(BodySection.log)
                        }
                        AdherenceHeatmapView(
                            totals: model.nutrition.totals,
                            target: model.profile.dailyMacroTarget,
                            targetHistory: model.nutrition.targetHistory,
                            timezone: model.profile.timezone,
                            phase: model.phase
                        )
                        .id(BodySection.fuel)
                        if !model.summaries.isEmpty {
                            WeeklyRecapList(
                                summaries: model.summaries,
                                totals: model.nutrition.totals,
                                target: model.profile.dailyMacroTarget,
                                targetHistory: model.nutrition.targetHistory,
                                presentsLatest: presentsLatestRecap
                            )
                            .id(BodySection.recaps)
                        }
                    }
                    .padding(.horizontal, Design.Space.gutter)
                    .padding(.top, Design.Space.s)
                    .padding(.bottom, Design.Space.xxxl)
                    .animation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion), value: snapshot.todayCheckIn)
                }
                .task {
                    guard let section = scrollTarget else { return }
                    scrollTarget = nil
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(section, anchor: .top)
                }
            }
            .background(AppBackground())
            .navigationTitle("Body")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion)) {
                            revealed.toggle()
                        }
                    } label: {
                        Image(systemName: revealed ? "eye" : "eye.slash")
                            .foregroundStyle(revealed ? Design.Color.pernambuco : Design.Color.textSecondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(revealed ? "Hide physique photos" : "Show physique photos")
                }
            }
            .refreshable { await model.load() }
        }
        // App-switcher snapshot + glances: nothing physique-shaped leaves the
        // screen while the scene isn't active.
        .blur(radius: scenePhase == .active ? 0 : 30)
        .overlay {
            if scenePhase != .active {
                Image(systemName: "lock.fill")
                    .font(.title)
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Design.Color.canvas.opacity(0.45))
                    .ignoresSafeArea()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { revealed = false }
        }
        .task { await model.load() }
        .task { await runPreviewAction() }
        .fullScreenCover(isPresented: $showsCamera) {
            checkInFlow(start: .camera)
                .navigationTransition(.zoom(sourceID: ZoomSource.checkIn, in: zoom))
        }
        .sheet(isPresented: $showsWeightEntry) {
            checkInFlow(start: .weight)
                .presentationDetents([.height(272)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(Design.Radius.sheet)
                .presentationBackground(Design.Color.surface1)
        }
        .fullScreenCover(item: $compare) { request in
            PhysiqueCompareView(
                checkIns: snapshot.photoCheckIns,
                units: units,
                loader: model.photos,
                trendPoints: snapshot.trendPoints,
                before: request.before)
                .navigationTransition(.zoom(sourceID: request.source, in: zoom))
        }
        .fullScreenCover(item: $viewer) { request in
            PhysiquePhotoViewer(
                checkIns: snapshot.photoCheckIns,
                units: units,
                timezone: model.profile.timezone,
                loader: model.photos,
                selection: request.id)
                .navigationTransition(.zoom(sourceID: request.source, in: zoom))
        }
        .confirmationDialog(
            "Delete this photo?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { checkIn in
            Button("Delete photo", role: .destructive) {
                Task { await model.removePhoto(checkIn) }
            }
        } message: { checkIn in
            Text(checkIn.weightKG == nil ? "It’s gone for good." : "It’s gone for good. That day’s weight stays.")
        }
        #if DEBUG
            .fullScreenCover(item: Binding(
                get: { previewReviewImage.map(PreviewImage.init) },
                set: { previewReviewImage = $0?.image })
            ) { item in
                BodyCheckInFlow(previewCapture: item.image, localDay: snapshot.today, units: units, service: model.service)
            }
        #endif
    }

    // MARK: Hero — where the bulk is

    /// The trend weight as the screen's one figure, how fast it's moving,
    /// how much of the bulk is loaded on the bar, and the line underneath.
    /// Nothing is said twice.
    @ViewBuilder
    private var hero: some View {
        if let currentKG = snapshot.meterCurrentKG ?? snapshot.trajectory.currentKG {
            VStack(alignment: .leading, spacing: 0) {
                Text(heroEyebrow).eyebrowStyle()
                heroFigure(currentKG)
                    .padding(.top, Design.Space.xs)
                paceLine
                if let meter = meter(currentKG) {
                    VStack(spacing: Design.Space.s) {
                        BarbellMeter(gainedPounds: meter.gainedPounds, goalPounds: meter.goalPounds)
                            .frame(height: 40)
                        meterCaption(meter)
                    }
                    .padding(.top, Design.Space.xl)
                }
                if snapshot.weighInCount > 0 {
                    WeightTrendChart(
                        points: snapshot.trendPoints,
                        goal: snapshot.goal,
                        today: snapshot.today,
                        units: units,
                        showsTrend: snapshot.showsTrendChart
                    )
                    .frame(height: 136)
                    .padding(.top, Design.Space.xxl)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heroEyebrow: String {
        let phase = switch snapshot.goal?.phase {
        case .bulk?: "Lean bulk"
        case .cut?: "Cut"
        default: "Weight"
        }
        guard let day = snapshot.dayNumber, snapshot.goal?.phase != .maintain else { return phase }
        return "\(phase) · Day \(day)"
    }

    private func heroFigure(_ kilograms: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Text(String(format: "%.1f", BodyUnits.display(kilograms, units: units)))
                .font(.system(size: heroSize, weight: .regular, design: .serif))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .contentTransition(.numericText(value: kilograms))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(BodyUnits.label(units))
                .font(Design.Typeface.display(.title3))
                .foregroundStyle(Design.Color.textSecondary)
            if snapshot.trend == nil {
                Text("self-reported")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "+0.6 lb a week · on pace": the rate quiet, the verdict in its colour.
    @ViewBuilder
    private var paceLine: some View {
        if let rate = snapshot.trend?.weeklyRateKG {
            let status = snapshot.trajectory.status
            let rateText = "\(BodyUnits.signed(BodyUnits.display(rate, units: units))) \(BodyUnits.label(units)) a week"
            HStack(spacing: Design.Space.s) {
                Text(rateText)
                    .foregroundStyle(Design.Color.textSecondary)
                if let label = status.label {
                    Circle()
                        .fill(Design.Color.textTertiary)
                        .frame(width: 3, height: 3)
                        .accessibilityHidden(true)
                    Text(label).foregroundStyle(status.color)
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        }
    }

    private struct Meter {
        let gainedPounds: Double
        let goalPounds: Double
        let gainedDisplay: Double
        let goalDisplay: Double
    }

    private func meter(_ currentKG: Double) -> Meter? {
        guard snapshot.goal?.phase != .maintain,
            let start = snapshot.meterStartKG, let target = snapshot.meterTargetKG
        else { return nil }
        let direction = snapshot.goal?.phase.direction ?? 1
        return Meter(
            gainedPounds: BodyUnits.pounds(currentKG - start) * direction,
            goalPounds: BodyUnits.pounds(target - start) * direction,
            gainedDisplay: BodyUnits.display(currentKG - start, units: units) * direction,
            goalDisplay: BodyUnits.display(abs(target - start), units: units)
        )
    }

    /// "+2.1 of 12.5 lb", centred under the bar like the number on a plate.
    private func meterCaption(_ meter: Meter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
            Text(BodyUnits.signed(meter.gainedDisplay))
                .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                .foregroundStyle(Design.Color.pernambuco)
            Text("of \(BodyUnits.format(meter.goalDisplay)) \(BodyUnits.label(units))")
                .font(.footnote)
                .foregroundStyle(Design.Color.textTertiary)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: Check-in line

    /// Today's check-in as one line: the photo (or the empty slot), what's
    /// done, and the one thing left to do.
    @ViewBuilder
    private var checkInLine: some View {
        Group {
            if let checkIn = snapshot.todayCheckIn, checkIn.hasPhoto {
                checkedInLine(checkIn)
            } else {
                checkInPrompt(snapshot.todayCheckIn)
            }
        }
        .transition(.ink(reduceMotion: reduceMotion))
    }

    private func checkInPrompt(_ checkIn: WeightCheckIn?) -> some View {
        HStack(alignment: .center, spacing: Design.Space.l) {
            Button {
                showsCamera = true
            } label: {
                CheckInPhotoPlaceholder()
                    .frame(width: 60, height: 80)
                    .matchedTransitionSource(id: ZoomSource.checkIn, in: zoom)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Take today’s photo")

            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text("Morning check-in")
                    .font(Design.Typeface.display(.title3))
                    .foregroundStyle(Design.Color.textPrimary)
                if let weight = checkIn?.weightKG {
                    Text("\(weightText(weight)) · photo still to take")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textSecondary)
                        .monospacedDigit()
                } else {
                    streakLabel(fallback: "Photo first, weight if you have it")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Design.Space.s) { promptButtons(checkIn) }
                    VStack(alignment: .leading, spacing: Design.Space.s) { promptButtons(checkIn) }
                }
                .padding(.top, Design.Space.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func promptButtons(_ checkIn: WeightCheckIn?) -> some View {
        Button {
            showsCamera = true
        } label: {
            Label("Check in", systemImage: "camera")
        }
        .buttonStyle(BodyPillButtonStyle(prominent: true))
        Button(checkIn?.hasWeight == true ? "Edit weight" : "Weight") {
            showsWeightEntry = true
        }
        .buttonStyle(BodyPillButtonStyle(prominent: false))
    }

    private func checkedInLine(_ checkIn: WeightCheckIn) -> some View {
        HStack(alignment: .center, spacing: Design.Space.l) {
            Button {
                if revealed {
                    viewer = ViewerRequest(id: checkIn.id, source: ZoomSource.checkIn)
                } else {
                    reveal()
                }
            } label: {
                BodyPhotoImage(path: checkIn.progressPhotoPath, loader: model.photos, maxPixel: BodyPhotoSize.thumb)
                    .physiqueVeil(revealed: revealed, iconSize: nil)
                    .frame(width: 45, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
                    .matchedTransitionSource(id: ZoomSource.checkIn, in: zoom)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today’s photo")
            .accessibilityHint(revealed ? "Opens the photo" : "Reveals photos")

            // Accessibility sizes stack the button under the text instead of
            // squeezing "Weight" into a column.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Space.m))
                : AnyLayout(HStackLayout(spacing: Design.Space.m))
            layout {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(checkedInTitle(checkIn))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.textPrimary)
                        .monospacedDigit()
                    streakLabel(fallback: checkIn.weightKG.map(weightText))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !checkIn.hasWeight {
                    Button {
                        showsWeightEntry = true
                    } label: {
                        Label("Weight", systemImage: "plus")
                    }
                    .buttonStyle(BodyPillButtonStyle(prominent: false))
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                showsCamera = true
            } label: {
                Label("Retake photo", systemImage: "camera")
            }
            Button {
                showsWeightEntry = true
            } label: {
                Label(checkIn.hasWeight ? "Edit weight" : "Add weight", systemImage: "scalemass")
            }
        }
        .accessibilityAction(named: "Retake photo") { showsCamera = true }
        .accessibilityAction(named: checkIn.hasWeight ? "Edit weight" : "Add weight") { showsWeightEntry = true }
    }

    /// "Checked in at 7:12 AM", plus the weight once it's in.
    private func checkedInTitle(_ checkIn: WeightCheckIn) -> String {
        var title = "Checked in"
        if let captured = checkIn.photoCapturedAt ?? (checkIn.hasPhoto ? checkIn.createdAt : nil) {
            title += " at \(BodyDayLabel.time(captured, timezone: model.profile.timezone))"
        }
        if let weight = checkIn.weightKG, snapshot.streak > 0 {
            title += " · \(weightText(weight))"
        }
        return title
    }

    /// The streak when there is one (oak, the warm secondary), else a quiet
    /// fallback line.
    @ViewBuilder
    private func streakLabel(fallback: String?) -> some View {
        if snapshot.streak > 0 {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "flame")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.oak)
                    .accessibilityHidden(true)
                Text(snapshot.streakAtRisk
                    ? "\(snapshot.streak)-day streak on the line"
                    : "\(snapshot.streak)-day streak")
                    .foregroundStyle(snapshot.streakAtRisk ? Design.Color.oak : Design.Color.textSecondary)
                    .contentTransition(.numericText(value: Double(snapshot.streak)))
            }
            .font(.footnote)
            .monospacedDigit()
        } else if let fallback {
            Text(fallback)
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
                .monospacedDigit()
        }
    }

    private func weightText(_ kilograms: Double) -> String {
        "\(BodyUnits.format(BodyUnits.display(kilograms, units: units))) \(BodyUnits.label(units))"
    }

    private func reveal() {
        withAnimation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion)) {
            revealed = true
        }
    }

    private func checkInFlow(start: BodyCheckInFlow.Start) -> some View {
        let today = snapshot.today
        let latestWeighInDay = model.checkIns.filter(\.hasWeight).map(\.localDay).max()
        return BodyCheckInFlow(
            localDay: today,
            units: units,
            existing: snapshot.todayCheckIn,
            start: start,
            ghostPath: snapshot.ghostCheckIn?.progressPhotoPath,
            service: model.service,
            photoLoader: model.photos,
            updatesProfileWeight: latestWeighInDay.map { today >= $0 } ?? true
        ) { saved in
            model.applySaved(saved)
            onCheckInSaved(saved)
        }
    }

    // MARK: Physique strip

    /// Newest first, one scrolling row; any photo opens the pager through
    /// all of them, so there's no "show all".
    private var physiqueStrip: some View {
        let photos = snapshot.photoCheckIns
        return VStack(alignment: .leading, spacing: Design.Space.m) {
            BodyCardHeader(title: "Physique") {
                if photos.count >= 2 {
                    Button {
                        compare = CompareRequest(before: nil, source: ZoomSource.compare)
                    } label: {
                        Text("Compare")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Design.Color.textSecondary)
                            .padding(.vertical, Design.Space.xs)
                            .contentShape(Rectangle())
                            .matchedTransitionSource(id: ZoomSource.compare, in: zoom)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Wipes between two check-ins")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Design.Space.s) {
                    ForEach(photos) { checkIn in
                        thumbnail(checkIn)
                    }
                }
            }
            .contentMargins(.horizontal, Design.Space.gutter, for: .scrollContent)
            .padding(.horizontal, -Design.Space.gutter)
        }
    }

    private func thumbnail(_ checkIn: WeightCheckIn) -> some View {
        let source = ZoomSource.photo(checkIn.id)
        return Button {
            if revealed {
                viewer = ViewerRequest(id: checkIn.id, source: source)
            } else {
                reveal()
            }
        } label: {
            VStack(alignment: .leading, spacing: Design.Space.xs + 2) {
                BodyPhotoImage(path: checkIn.progressPhotoPath, loader: model.photos, maxPixel: BodyPhotoSize.thumb)
                    .physiqueVeil(revealed: revealed, iconSize: nil)
                    .frame(width: 66, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
                    .matchedTransitionSource(id: source, in: zoom)
                Text(thumbnailLabel(checkIn))
                    .font(Design.Typeface.numeral(.caption2, weight: .medium))
                    .foregroundStyle(checkIn.localDay == snapshot.today ? Design.Color.textSecondary : Design.Color.textTertiary)
                    .monospacedDigit()
                    .padding(.leading, Design.Space.xxs)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                compare = CompareRequest(before: checkIn, source: source)
            } label: {
                Label("Compare with latest", systemImage: "rectangle.split.2x1")
            }
            Button(role: .destructive) {
                pendingDelete = checkIn
            } label: {
                Label("Delete photo", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Check-in photo, \(BodyDayLabel.short(checkIn.localDay))")
        .accessibilityHint(revealed ? "Opens the photo" : "Reveals photos")
        .accessibilityAddTraits(.isButton)
    }

    private func thumbnailLabel(_ checkIn: WeightCheckIn) -> String {
        if let start = snapshot.goal?.startDay, let days = LocalDayMath.days(from: start, to: checkIn.localDay), days >= 0 {
            return "D\(days + 1)"
        }
        return BodyDayLabel.short(checkIn.localDay)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .foregroundStyle(Design.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Preview hooks

    private func runPreviewAction() async {
        guard let action = previewAction else { return }
        previewAction = nil
        try? await Task.sleep(for: .milliseconds(450))
        switch action {
        case .compare: compare = CompareRequest(before: nil, source: ZoomSource.compare)
        case .camera: showsCamera = true
        case .weight: showsWeightEntry = true
        case .viewer:
            if let first = snapshot.photoCheckIns.first {
                viewer = ViewerRequest(id: first.id, source: ZoomSource.photo(first.id))
            }
        case .recap: presentsLatestRecap = true
        case .review:
            #if DEBUG
                previewReviewImage = BodyFixtureArt.cameraFixture
            #else
                break
            #endif
        }
    }
}

enum BodyPreviewAction: String {
    case compare, camera, review, weight, viewer, recap
}

enum BodySection: String, Hashable {
    case hero, weight, log, fuel, recaps
}

/// Where a full-screen cover zooms out of (and back into).
private enum ZoomSource {
    static let checkIn = "body.checkin"
    static let compare = "body.compare"
    static func photo(_ id: UUID) -> String { "body.photo.\(id.uuidString)" }
}

private struct CompareRequest: Identifiable {
    let id = UUID()
    let before: WeightCheckIn?
    let source: String
}

private struct ViewerRequest: Identifiable {
    let id: UUID
    let source: String
}

#if DEBUG
    private struct PreviewImage: Identifiable {
        let image: UIImage
        var id: ObjectIdentifier { ObjectIdentifier(image) }
    }
#endif
