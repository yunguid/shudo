import SwiftUI

/// The Body tab: the daily check-in ritual (photo first, weight optional),
/// the lean-bulk barbell meter, the weight trend, the physique log with its
/// privacy veil and compare wipe, the Fuel heatmap, and the weekly recap
/// archive. Owns its NavigationStack; mount it directly in a tab.
struct BodyScreen: View {
    @StateObject private var model: BodyViewModel
    private let onCheckInSaved: (WeightCheckIn) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Bool
    @State private var showsCamera = false
    @State private var showsWeightEntry = false
    @State private var compare: CompareRequest?
    @State private var viewer: ViewerRequest?
    @State private var pendingDelete: WeightCheckIn?
    @State private var showsAllPhotos = false
    @State private var previewAction: BodyPreviewAction?
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
                    VStack(alignment: .leading, spacing: 14) {
                        if let message = model.errorMessage {
                            errorBanner(message)
                        }
                        checkInHero.id(BodySection.hero)
                        if snapshot.goal?.phase != .maintain, snapshot.meterTargetKG != nil, snapshot.meterStartKG != nil {
                            bulkMeter.id(BodySection.meter)
                        }
                        trendCard.id(BodySection.trend)
                        physiqueLog.id(BodySection.log)
                        AdherenceHeatmapView(
                            totals: model.nutrition.totals,
                            target: model.profile.dailyMacroTarget,
                            targetHistory: model.nutrition.targetHistory,
                            timezone: model.profile.timezone,
                            phase: model.phase
                        )
                        .id(BodySection.fuel)
                        WeeklyRecapList(summaries: model.summaries, isLoading: model.isLoading && !model.hasLoaded)
                            .id(BodySection.recaps)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .task {
                    guard let section = scrollTarget else { return }
                    scrollTarget = nil
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(section, anchor: .top)
                }
            }
            .background(Design.Color.canvas.ignoresSafeArea())
            .navigationTitle("Body")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion)) {
                            revealed.toggle()
                        }
                    } label: {
                        Image(systemName: revealed ? "eye.fill" : "eye.slash.fill")
                            .foregroundStyle(revealed ? Design.Color.ember : Design.Color.textSecondary)
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
                    .font(.largeTitle)
                    .foregroundStyle(Design.Color.textSecondary)
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
        .fullScreenCover(isPresented: $showsCamera) { checkInFlow(start: .camera) }
        .sheet(isPresented: $showsWeightEntry) {
            checkInFlow(start: .weight)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(Design.Radius.sheet)
        }
        .fullScreenCover(item: $compare) { request in
            PhysiqueCompareView(
                checkIns: snapshot.photoCheckIns,
                units: units,
                loader: model.photos,
                trendPoints: snapshot.trendPoints,
                before: request.before)
        }
        .fullScreenCover(item: $viewer) { request in
            PhysiquePhotoViewer(
                checkIns: snapshot.photoCheckIns,
                units: units,
                timezone: model.profile.timezone,
                loader: model.photos,
                selection: request.id)
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
            Text(checkIn.weightKG == nil
                 ? "The photo is removed from Shudo for good."
                 : "The photo is removed for good. That day’s weight stays.")
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

    // MARK: Check-in hero

    private var checkInHero: some View {
        let todayCheckIn = snapshot.todayCheckIn
        return HStack(alignment: .top, spacing: 14) {
            Button {
                if let todayCheckIn, todayCheckIn.hasPhoto {
                    if revealed { viewer = ViewerRequest(id: todayCheckIn.id) } else { revealed = true }
                } else {
                    showsCamera = true
                }
            } label: {
                Group {
                    if let path = todayCheckIn?.progressPhotoPath {
                        BodyPhotoImage(path: path, loader: model.photos, maxPixel: BodyPhotoSize.hero)
                            .physiqueVeil(revealed: revealed)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Design.Color.ember, lineWidth: 1.5))
                    } else {
                        CheckInPhotoPlaceholder(label: "Snap")
                    }
                }
                .frame(width: 112, height: 150)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todayCheckIn?.hasPhoto == true ? "Today's photo" : "Snap today's check-in")

            VStack(alignment: .leading, spacing: 6) {
                Text(heroEyebrow).eyebrowStyle(Design.Color.ember)
                Text(heroTitle)
                    .font(Design.Typeface.screenTitle)
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text(heroDetail)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot.streak > 0 {
                    Label(
                        snapshot.streakAtRisk
                            ? "\(snapshot.streak)-day streak on the line"
                            : "\(snapshot.streak)-day streak",
                        systemImage: "flame.fill"
                    )
                    .font(Design.Typeface.meta)
                    .foregroundStyle(Design.Color.ember)
                    .contentTransition(.numericText(value: Double(snapshot.streak)))
                }
                Spacer(minLength: 2)
                heroActions(todayCheckIn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Design.Radius.cardLarge)
    }

    private var heroEyebrow: String {
        snapshot.dayNumber.map { "Today · Day \($0)" } ?? "Today"
    }

    private var heroTitle: String {
        switch (snapshot.todayCheckIn?.hasPhoto, snapshot.todayCheckIn?.hasWeight) {
        case (true?, _): "Checked in"
        case (_, true?): "Weighed in"
        default: "Snap today’s check-in"
        }
    }

    private var heroDetail: String {
        guard let checkIn = snapshot.todayCheckIn else {
            return "Same spot, same light, 20 seconds. Weight optional."
        }
        var parts: [String] = []
        if let captured = checkIn.photoCapturedAt ?? (checkIn.hasPhoto ? checkIn.createdAt : nil) {
            parts.append(BodyDayLabel.time(captured, timezone: model.profile.timezone))
        }
        if let pose = checkIn.photoPose { parts.append(pose.label.lowercased()) }
        if let weight = checkIn.weightKG {
            parts.append("\(BodyUnits.format(BodyUnits.display(weight, units: units))) \(BodyUnits.label(units))")
        } else {
            parts.append("no weight yet")
        }
        if !checkIn.hasPhoto { parts.append("photo still open") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func heroActions(_ checkIn: WeightCheckIn?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { heroButtons(checkIn) }
            VStack(alignment: .leading, spacing: 8) { heroButtons(checkIn) }
        }
    }

    @ViewBuilder
    private func heroButtons(_ checkIn: WeightCheckIn?) -> some View {
        if checkIn?.hasPhoto == true {
            Button {
                showsWeightEntry = true
            } label: {
                Label(checkIn?.hasWeight == true ? "Edit weight" : "Add weight", systemImage: "scalemass.fill")
            }
            .buttonStyle(BodyPillButtonStyle(prominent: checkIn?.hasWeight != true))
            Button("Retake") { showsCamera = true }
                .buttonStyle(BodyPillButtonStyle(prominent: false))
        } else {
            Button {
                showsCamera = true
            } label: {
                Label(checkIn == nil ? "Snap" : "Add photo", systemImage: "camera.fill")
            }
            .buttonStyle(BodyPillButtonStyle(prominent: true))
            Button {
                showsWeightEntry = true
            } label: {
                Text(checkIn?.hasWeight == true ? "Edit weight" : "Weight only")
            }
            .buttonStyle(BodyPillButtonStyle(prominent: false))
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

    // MARK: Bulk meter

    private var bulkMeter: some View {
        let start = snapshot.meterStartKG ?? 0
        let target = snapshot.meterTargetKG ?? 0
        let current = snapshot.meterCurrentKG ?? start
        let direction = snapshot.goal?.phase.direction ?? 1
        let gainedPounds = BodyUnits.pounds(current - start) * direction
        let goalPounds = BodyUnits.pounds(target - start) * direction
        let progress = BodyUnits.display(current - start, units: units) * direction
        let total = BodyUnits.display(abs(target - start), units: units)
        let isSelfReported = snapshot.trend == nil

        return VStack(alignment: .leading, spacing: 12) {
            BodyCardHeader(title: snapshot.goal?.phase == .cut ? "Cut" : "Lean bulk") {
                Text("\(BodyUnits.format(BodyUnits.display(start, units: units))) → \(BodyUnits.format(BodyUnits.display(target, units: units))) \(BodyUnits.label(units))")
                    .font(Design.Typeface.numeral(.caption, weight: .semibold))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", BodyUnits.display(current, units: units)))
                    .font(Design.Typeface.numeral(.largeTitle, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.textPrimary)
                    .contentTransition(.numericText(value: current))
                Text(BodyUnits.label(units)).font(.headline).foregroundStyle(Design.Color.textSecondary)
                if isSelfReported {
                    Text("self-reported")
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 4)
                Text(BodyUnits.signed(progress))
                    .font(Design.Typeface.numeral(.title3, weight: .bold))
                    .foregroundStyle(Design.Color.ember)
                    .monospacedDigit()
                Text("of \(BodyUnits.format(total))")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
            BarbellMeter(gainedPounds: gainedPounds, goalPounds: goalPounds)
                .frame(height: 64)
            Text(TrajectoryPolicy.sentence(snapshot.trajectory, goal: snapshot.goal, units: units))
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .cardSurface(radius: Design.Radius.cardLarge)
    }

    // MARK: Trend

    private var trendCard: some View {
        let count = snapshot.weighInCount
        let showsTrend = snapshot.showsTrendChart
        let chart = WeightTrendChart(
            points: snapshot.trendPoints,
            goal: snapshot.goal,
            today: snapshot.today,
            units: units,
            showsTrend: showsTrend
        )
        let weeks = max(1, Int((Double(LocalDayMath.days(from: chart.windowStart, to: snapshot.today) ?? 7) / 7).rounded()))
        return VStack(alignment: .leading, spacing: 10) {
            BodyCardHeader(title: "Trend · \(weeks) weeks") {
                trendBadge(showsTrend: showsTrend, count: count)
            }
            chart
                .frame(height: showsTrend ? 150 : 110)
            if showsTrend, let trend = snapshot.trend {
                HStack(spacing: 14) {
                    trendStat(
                        "\(BodyUnits.format(BodyUnits.display(trend.trendKG, units: units)))",
                        caption: "trend \(BodyUnits.label(units))")
                    if let average = trend.sevenDayAverageKG {
                        trendStat(
                            BodyUnits.format(BodyUnits.display(average, units: units)), caption: "7-day avg")
                    }
                    trendStat("\(trend.weighInsLast7)", caption: "weigh-ins this week")
                    Spacer(minLength: 0)
                }
            } else {
                Text(count == 0
                     ? "Weigh-ins start when your scale lands. The trend line shows up at \(WeightTrendPolicy.minChartSamples)."
                     : "\(WeightTrendPolicy.minChartSamples - count) more weigh-in\(WeightTrendPolicy.minChartSamples - count == 1 ? "" : "s") and the trend line shows up.")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .cardSurface(radius: Design.Radius.cardLarge)
    }

    @ViewBuilder
    private func trendBadge(showsTrend: Bool, count: Int) -> some View {
        if showsTrend, let rate = snapshot.trend?.weeklyRateKG {
            let status = snapshot.trajectory.status
            Text("\(BodyUnits.signed(BodyUnits.display(rate, units: units))) \(BodyUnits.label(units))/wk · \(status.label)")
                .font(Design.Typeface.meta)
                .foregroundStyle(status.color)
        } else if showsTrend {
            Text("pace needs \(WeightTrendPolicy.minRateSamples) in 3 wks")
                .font(Design.Typeface.meta)
                .foregroundStyle(Design.Color.textTertiary)
        } else {
            Text("\(count)/\(WeightTrendPolicy.minChartSamples) weigh-ins")
                .font(Design.Typeface.meta)
                .foregroundStyle(Design.Color.textTertiary)
                .monospacedDigit()
        }
    }

    private func trendStat(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Design.Typeface.numeral(.headline, weight: .bold))
                .foregroundStyle(Design.Color.textPrimary)
                .monospacedDigit()
            Text(caption).font(Design.Typeface.meta).foregroundStyle(Design.Color.textTertiary)
        }
    }

    // MARK: Physique log

    private var physiqueLog: some View {
        let photos = snapshot.photoCheckIns
        let visible = showsAllPhotos ? photos : Array(photos.prefix(12))
        return VStack(alignment: .leading, spacing: 10) {
            BodyCardHeader(title: "Physique log") {
                Button {
                    compare = CompareRequest(before: nil)
                } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(photos.count >= 2 ? Design.Color.ember : Design.Color.textDisabled)
                }
                .buttonStyle(.plain)
                .disabled(photos.count < 2)
            }
            if photos.isEmpty {
                Text("Your first check-in photo starts the log. Same pose daily, and the compare wipe does the rest.")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(visible) { checkIn in
                        thumbnail(checkIn)
                    }
                }
                if photos.count > 12 {
                    Button(showsAllPhotos ? "Show fewer" : "Show all \(photos.count)") {
                        withAnimation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion)) {
                            showsAllPhotos.toggle()
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.Color.ember)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .cardSurface(radius: Design.Radius.cardLarge)
    }

    private func thumbnail(_ checkIn: WeightCheckIn) -> some View {
        Button {
            if revealed { viewer = ViewerRequest(id: checkIn.id) } else { revealed = true }
        } label: {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    BodyPhotoImage(path: checkIn.progressPhotoPath, loader: model.photos, maxPixel: BodyPhotoSize.thumb)
                        .physiqueVeil(revealed: revealed, iconSize: .caption)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(thumbnailLabel(checkIn))
                        .font(Design.Typeface.numeral(.caption2, weight: .bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(5)
                }
                .overlay(alignment: .topTrailing) {
                    if checkIn.hasWeight {
                        Image(systemName: "scalemass.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Design.Color.honey)
                            .padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                compare = CompareRequest(before: checkIn)
            } label: {
                Label("Compare with latest", systemImage: "rectangle.split.2x1")
            }
            Button(role: .destructive) {
                pendingDelete = checkIn
            } label: {
                Label("Delete photo", systemImage: "trash")
            }
        }
        .accessibilityLabel("Check-in photo, \(BodyDayLabel.short(checkIn.localDay))")
        .accessibilityHint(revealed ? "Opens the photo" : "Reveals photos")
    }

    private func thumbnailLabel(_ checkIn: WeightCheckIn) -> String {
        if let start = snapshot.goal?.startDay, let days = LocalDayMath.days(from: start, to: checkIn.localDay), days >= 0 {
            return "D\(days + 1)"
        }
        return BodyDayLabel.short(checkIn.localDay)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Design.Color.textPrimary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Color.danger.opacity(0.16), in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
    }

    // MARK: Preview hooks

    private func runPreviewAction() async {
        guard let action = previewAction else { return }
        previewAction = nil
        try? await Task.sleep(for: .milliseconds(450))
        switch action {
        case .compare: compare = CompareRequest(before: nil)
        case .camera: showsCamera = true
        case .weight: showsWeightEntry = true
        case .viewer: if let first = snapshot.photoCheckIns.first { viewer = ViewerRequest(id: first.id) }
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
    case compare, camera, review, weight, viewer
}

enum BodySection: String, Hashable {
    case hero, meter, trend, log, fuel, recaps
}

private struct CompareRequest: Identifiable {
    let id = UUID()
    let before: WeightCheckIn?
}

private struct ViewerRequest: Identifiable {
    let id: UUID
}

#if DEBUG
    private struct PreviewImage: Identifiable {
        let image: UIImage
        var id: ObjectIdentifier { ObjectIdentifier(image) }
    }
#endif
