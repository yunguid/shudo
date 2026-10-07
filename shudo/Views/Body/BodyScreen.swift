import SwiftUI

/// The Body tab: the daily check-in (photo first, weight optional), the
/// weight card (bulk barbell + trend), the physique strip with its privacy
/// veil and compare wipe, the Fuel heatmap, and the weekly recaps. Owns its
/// NavigationStack; mount it directly in a tab.
struct BodyScreen: View {
    @StateObject private var model: BodyViewModel
    private let onCheckInSaved: (WeightCheckIn) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                    VStack(alignment: .leading, spacing: 14) {
                        if let message = model.errorMessage {
                            errorBanner(message)
                        }
                        checkInCard.id(BodySection.hero)
                        weightCard.id(BodySection.weight)
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                    .animation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion), value: snapshot.todayCheckIn)
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
                .presentationDetents([.height(260)])
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

    // MARK: Check-in

    /// Before today's photo the check-in is the screen's hero; once it's in,
    /// it shrinks to one quiet row and the weight card leads.
    @ViewBuilder
    private var checkInCard: some View {
        if let checkIn = snapshot.todayCheckIn, checkIn.hasPhoto {
            checkedInRow(checkIn)
                .transition(.opacity)
        } else {
            checkInPrompt(snapshot.todayCheckIn)
                .transition(.opacity)
        }
    }

    private func checkInPrompt(_ checkIn: WeightCheckIn?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                showsCamera = true
            } label: {
                CheckInPhotoPlaceholder()
                    .frame(width: 104, height: 138)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Take today’s photo")

            VStack(alignment: .leading, spacing: 6) {
                if let day = snapshot.dayNumber {
                    Text("Day \(day)").eyebrowStyle(Design.Color.ember)
                }
                Text("Check in")
                    .font(Design.Typeface.screenTitle)
                    .foregroundStyle(Design.Color.textPrimary)
                if let weight = checkIn?.weightKG {
                    Text(weightText(weight))
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .monospacedDigit()
                }
                streakLabel
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { promptButtons(checkIn) }
                    VStack(alignment: .leading, spacing: 8) { promptButtons(checkIn) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Design.Radius.cardLarge)
    }

    @ViewBuilder
    private func promptButtons(_ checkIn: WeightCheckIn?) -> some View {
        Button {
            showsCamera = true
        } label: {
            Label("Snap", systemImage: "camera.fill")
        }
        .buttonStyle(BodyPillButtonStyle(prominent: true))
        Button(checkIn?.hasWeight == true ? "Edit weight" : "Weight") {
            showsWeightEntry = true
        }
        .buttonStyle(BodyPillButtonStyle(prominent: false))
    }

    private func checkedInRow(_ checkIn: WeightCheckIn) -> some View {
        HStack(spacing: 14) {
            Button {
                if revealed { viewer = ViewerRequest(id: checkIn.id) } else { revealed = true }
            } label: {
                BodyPhotoImage(path: checkIn.progressPhotoPath, loader: model.photos, maxPixel: BodyPhotoSize.thumb)
                    .physiqueVeil(revealed: revealed, iconSize: .caption)
                    .frame(width: 60, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Design.Color.ember, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today’s photo")
            .accessibilityHint(revealed ? "Opens the photo" : "Reveals photos")

            // Accessibility sizes stack the button under the text instead of
            // squeezing "Weight" into a column.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 14))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Checked in")
                        .font(.headline)
                        .foregroundStyle(Design.Color.textPrimary)
                    Text(checkedInDetail(checkIn))
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .monospacedDigit()
                    streakLabel
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
        .padding(12)
        .cardSurface(radius: Design.Radius.cardLarge)
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

    private func checkedInDetail(_ checkIn: WeightCheckIn) -> String {
        var parts: [String] = []
        if let captured = checkIn.photoCapturedAt ?? (checkIn.hasPhoto ? checkIn.createdAt : nil) {
            parts.append(BodyDayLabel.time(captured, timezone: model.profile.timezone))
        }
        if let weight = checkIn.weightKG { parts.append(weightText(weight)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var streakLabel: some View {
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
    }

    private func weightText(_ kilograms: Double) -> String {
        "\(BodyUnits.format(BodyUnits.display(kilograms, units: units))) \(BodyUnits.label(units))"
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

    // MARK: Weight

    /// One card for the number: trend weight as the hero, the barbell for
    /// how much of the bulk is loaded, and the chart underneath. Rate and
    /// pace sit in the header; nothing is said twice.
    @ViewBuilder
    private var weightCard: some View {
        if let currentKG = snapshot.meterCurrentKG ?? snapshot.trajectory.currentKG {
            let goal = snapshot.goal
            let showsMeter = goal?.phase != .maintain && snapshot.meterStartKG != nil && snapshot.meterTargetKG != nil
            VStack(alignment: .leading, spacing: 14) {
                BodyCardHeader(title: phaseTitle) { paceBadge }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        heroWeight(currentKG)
                        Spacer(minLength: 8)
                        if showsMeter { meterProgress(currentKG) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) { heroWeight(currentKG) }
                        if showsMeter {
                            HStack(alignment: .firstTextBaseline, spacing: 6) { meterProgress(currentKG) }
                        }
                    }
                }
                if showsMeter, let start = snapshot.meterStartKG, let target = snapshot.meterTargetKG {
                    let direction = goal?.phase.direction ?? 1
                    BarbellMeter(
                        gainedPounds: BodyUnits.pounds(currentKG - start) * direction,
                        goalPounds: BodyUnits.pounds(target - start) * direction
                    )
                    .frame(height: 64)
                }
                if snapshot.weighInCount > 0 {
                    WeightTrendChart(
                        points: snapshot.trendPoints,
                        goal: goal,
                        today: snapshot.today,
                        units: units,
                        showsTrend: snapshot.showsTrendChart
                    )
                    .frame(height: 150)
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .cardSurface(radius: Design.Radius.cardLarge)
        }
    }

    private var phaseTitle: String {
        switch snapshot.goal?.phase {
        case .bulk?: "Lean bulk"
        case .cut?: "Cut"
        default: "Weight"
        }
    }

    @ViewBuilder
    private var paceBadge: some View {
        if let rate = snapshot.trend?.weeklyRateKG {
            let status = snapshot.trajectory.status
            let rateText = "\(BodyUnits.signed(BodyUnits.display(rate, units: units))) \(BodyUnits.label(units))/wk"
            Text([rateText, status.label].compactMap { $0 }.joined(separator: " · "))
                .font(Design.Typeface.meta)
                .foregroundStyle(status.color)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func heroWeight(_ kilograms: Double) -> some View {
        Text(String(format: "%.1f", BodyUnits.display(kilograms, units: units)))
            .font(Design.Typeface.numeral(.largeTitle, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Design.Color.textPrimary)
            .contentTransition(.numericText(value: kilograms))
        Text(BodyUnits.label(units))
            .font(.headline)
            .foregroundStyle(Design.Color.textSecondary)
        if snapshot.trend == nil {
            Text("self-reported")
                .font(Design.Typeface.meta)
                .foregroundStyle(Design.Color.textTertiary)
        }
    }

    @ViewBuilder
    private func meterProgress(_ currentKG: Double) -> some View {
        let start = snapshot.meterStartKG ?? currentKG
        let target = snapshot.meterTargetKG ?? currentKG
        let direction = snapshot.goal?.phase.direction ?? 1
        Text(BodyUnits.signed(BodyUnits.display(currentKG - start, units: units) * direction))
            .font(Design.Typeface.numeral(.title3, weight: .bold))
            .foregroundStyle(Design.Color.ember)
            .monospacedDigit()
        Text("of \(BodyUnits.format(BodyUnits.display(abs(target - start), units: units)))")
            .font(.footnote)
            .foregroundStyle(Design.Color.textTertiary)
            .monospacedDigit()
    }

    // MARK: Physique strip

    /// Newest first, one scrolling row; any photo opens the pager through
    /// all of them, so there's no "show all".
    private var physiqueStrip: some View {
        let photos = snapshot.photoCheckIns
        return VStack(alignment: .leading, spacing: 12) {
            BodyCardHeader(title: "Physique") {
                if photos.count >= 2 {
                    Button {
                        compare = CompareRequest(before: nil)
                    } label: {
                        Label("Compare", systemImage: "rectangle.split.2x1")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Design.Color.ember)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(photos) { checkIn in
                        thumbnail(checkIn)
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
        }
        .padding(.vertical, 16)
        .cardSurface(radius: Design.Radius.cardLarge)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous))
    }

    private func thumbnail(_ checkIn: WeightCheckIn) -> some View {
        Button {
            if revealed { viewer = ViewerRequest(id: checkIn.id) } else { revealed = true }
        } label: {
            BodyPhotoImage(path: checkIn.progressPhotoPath, loader: model.photos, maxPixel: BodyPhotoSize.thumb)
                .physiqueVeil(revealed: revealed, iconSize: nil)
                .frame(width: 76, height: 101)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(thumbnailLabel(checkIn))
                        .font(Design.Typeface.numeral(.caption2, weight: .bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
