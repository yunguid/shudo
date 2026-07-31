import SwiftUI
import UIKit

enum DayEdgeSwipePolicy {
    enum Edge: Equatable {
        case left
        case right
    }

    static let edgeWidth: CGFloat = 24
    static let minimumTravel: CGFloat = 72
    static let minimumFlickTravel: CGFloat = 28
    static let projectedFlickTravel: CGFloat = 130
    static let horizontalDominance: CGFloat = 1.35

    static func originatingEdge(startX: CGFloat, containerWidth: CGFloat) -> Edge? {
        guard containerWidth > edgeWidth * 2 else { return nil }
        if startX <= edgeWidth { return .left }
        if startX >= containerWidth - edgeWidth { return .right }
        return nil
    }

    static func dayDelta(
        startX: CGFloat,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        containerWidth: CGFloat
    ) -> Int? {
        guard let edge = originatingEdge(startX: startX, containerWidth: containerWidth) else {
            return nil
        }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard horizontal >= minimumFlickTravel,
            horizontal >= vertical * horizontalDominance
        else { return nil }

        let directionMatchesEdge =
            switch edge {
            case .left:
                translation.width > 0 && predictedEndTranslation.width > 0
            case .right:
                translation.width < 0 && predictedEndTranslation.width < 0
            }
        guard directionMatchesEdge else { return nil }

        let passedDistance = horizontal >= minimumTravel
        let passedVelocityProjection = abs(predictedEndTranslation.width) >= projectedFlickTravel
        guard passedDistance || passedVelocityProjection else { return nil }
        return edge == .left ? -1 : 1
    }

    static func previewOffset(
        startX: CGFloat,
        translation: CGSize,
        containerWidth: CGFloat
    ) -> CGFloat {
        guard let edge = originatingEdge(startX: startX, containerWidth: containerWidth),
            abs(translation.width) > abs(translation.height) * 1.1
        else { return 0 }
        switch edge {
        case .left where translation.width > 0:
            return min(18, translation.width * 0.12)
        case .right where translation.width < 0:
            return max(-18, translation.width * 0.12)
        default:
            return 0
        }
    }
}

struct TodayView: View {
    let profile: Profile
    private let loadsRemotely: Bool
    /// Preview/UI-test affordance: a fixture detail used for pushed meal
    /// screens so the full log → detail → correction journey runs offline.
    private let previewEntryDetail: SupabaseService.EntryDetail?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var todayCalorieFontSize: CGFloat = 32
    // Matches EntryCard's thumbnail metric so the divider inset tracks Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var entryThumb: CGFloat = 44
    @StateObject private var vm: TodayViewModel
    @ObservedObject private var router = AppRouter.shared
    @State private var formatterCache = DayFormatterCache()
    /// The composer's recorder, owned here so a mic tap can start the audio
    /// warm-up immediately — overlapping session activation with the sheet
    /// presentation instead of waiting for the composer to appear. Held in a
    /// non-observing box: the recorder's 16Hz meter updates must re-render
    /// only the composer, never this whole screen.
    @StateObject private var composerAudioHolder = UnobservedHolder(AudioRecorder())

    @State private var isShowingAccount = false
    @State private var isShowingDatePicker = false
    @State private var isShowingWeightCheckIn = false
    @State private var weightCheckIns: [WeightCheckIn] = []
    @State private var isLoadingWeightCheckIns = false
    @State private var composerAutoStartsRecording = false
    @State private var showErrorAlert = false
    @State private var entryPendingDeletion: Entry?
    @GestureState private var daySwipePreview: CGFloat = 0

    init(profile: Profile) {
        self.profile = profile
        loadsRemotely = true
        previewEntryDetail = nil
        _vm = StateObject(
            wrappedValue: TodayViewModel(
                profile: profile,
                api: APIService(
                    supabaseUrl: AppConfig.supabaseURL,
                    supabaseAnonKey: AppConfig.supabaseAnonKey,
                    sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
                )
            ))
    }

    init(
        profile: Profile,
        previewViewModel: TodayViewModel,
        previewEntryDetail: SupabaseService.EntryDetail? = nil
    ) {
        self.profile = profile
        loadsRemotely = false
        self.previewEntryDetail = previewEntryDetail
        _vm = StateObject(wrappedValue: previewViewModel)
    }

    @ViewBuilder
    private func entryDetailDestination(for entry: Entry) -> some View {
        let submitCorrection: (EntryCorrectionSubmission) -> Void = { submission in
            vm.submitCorrection(entryId: entry.id, submission: submission)
        }
        if let previewEntryDetail {
            EntryDetailView(
                entryId: entry.id,
                previewDetail: previewEntryDetail,
                onCorrectionSubmit: submitCorrection
            )
        } else {
            EntryDetailView(
                entryId: entry.id,
                seed: entry,
                onCorrectionSubmit: submitCorrection
            )
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    AppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            dayNavigator
                            if loadsRemotely {
                                weightCheckInCard
                            }
                            macroStrip
                            mealList
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 110)
                    }
                    .refreshable {
                        guard loadsRemotely else { return }
                        await vm.load(day: vm.currentDay)
                    }
                    .offset(x: daySwipePreview)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    daySwipeGesture(containerWidth: geometry.size.width),
                    including: daySwipeIsEnabled ? .all : .none
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingAccount = true
                    } label: {
                        AccountAvatarIcon(
                            userId: vm.profile?.userId ?? profile.userId,
                            avatarPath: vm.profile?.avatarPath
                        )
                    }
                    .accessibilityLabel("Account")
                }
            }
            .safeAreaInset(edge: .bottom) { captureDock }
        }
        .sheet(isPresented: $vm.isPresentingComposer, onDismiss: {
            let recorder = composerAudioHolder.value
            CaptureDiagnostics.record(.composerDismissed, state: recorder.controlState.rawValue)
            recorder.discardRecording()
        }) {
            let capturedDay = vm.currentDay
            EntryComposerView(
                selectedDay: capturedDay,
                timezone: vm.profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier,
                autoStartRecording: composerAutoStartsRecording,
                audio: composerAudioHolder.value
            ) { text, audio, imageJPEG, clientRequestId in
                vm.acceptEntrySubmission(
                    text: text,
                    audioData: audio,
                    imageJPEG: imageJPEG,
                    for: capturedDay,
                    clientRequestId: clientRequestId
                )
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        }
        .sheet(isPresented: $isShowingAccount) {
            NavigationStack {
                AccountView(initialProfile: vm.profile ?? profile) { updatedProfile in
                    vm.applyProfile(updatedProfile)
                }
            }
        }
        .sheet(isPresented: $isShowingWeightCheckIn) {
            WeightCheckInView(
                localDay: selectedLocalDay,
                units: vm.profile?.units ?? profile.units,
                existing: selectedWeightCheckIn
            ) { saved in
                weightCheckIns.removeAll { $0.localDay == saved.localDay }
                weightCheckIns.append(saved)
                weightCheckIns.sort { $0.localDay > $1.localDay }
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        }
        .popover(isPresented: $isShowingDatePicker) {
            DatePicker(
                "Day",
                selection: Binding(
                    get: { vm.currentDay },
                    set: { selected in
                        isShowingDatePicker = false
                        Task { await vm.load(day: selected) }
                    }
                ),
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .tint(Design.Color.accentPrimary)
            .padding()
            .presentationCompactAdaptation(.sheet)
        }
        .onAppear { handleCaptureRequest(router.captureRequest) }
        .task {
            guard loadsRemotely else { return }
            await loadWeightCheckIns()
        }
        .onChange(of: router.captureRequest) { _, request in handleCaptureRequest(request) }
        .onChange(of: profile) { _, updated in
            guard loadsRemotely else { return }
            Task { await vm.loadFor(profile: updated) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard loadsRemotely, phase == .active else { return }
            Task { await vm.reconcileAfterActivation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            guard loadsRemotely else { return }
            Task { await vm.reconcileAfterActivation() }
        }
        .onChange(of: vm.errorMessage) { _, message in showErrorAlert = message != nil }
        .alert("Couldn’t finish that", isPresented: $showErrorAlert) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "Please try again.")
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let entry = entryPendingDeletion else { return }
                entryPendingDeletion = nil
                Task { await vm.deleteEntry(entry) }
            }
            Button("Cancel", role: .cancel) { entryPendingDeletion = nil }
        } message: {
            Text("This removes the meal from your log and can’t be undone.")
        }
    }

    private var dayNavigator: some View {
        HStack(spacing: 14) {
            dayArrow(systemImage: "chevron.left", delta: -1, disabled: false)

            Button {
                isShowingDatePicker = true
            } label: {
                VStack(spacing: 2) {
                    Text(dayTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Design.Color.ink)
                    Text(shortDate)
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose another date")

            dayArrow(systemImage: "chevron.right", delta: 1, disabled: vm.isPinnedToToday)
        }
    }

    private func dayArrow(systemImage: String, delta: Int, disabled: Bool) -> some View {
        let direction = delta < 0 ? "earlier" : "later"
        return Button {
            shiftDay(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(disabled ? Design.Color.subtle : Design.Color.ink)
                .frame(width: 44, height: 44)
                .background(Design.Color.elevated, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(delta < 0 ? "Previous day" : "Next day")
        .accessibilityHint(disabled ? "Already showing today" : "Shows one day \(direction)")
    }

    private var macroStrip: some View {
        let target = vm.effectiveTarget
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily summary")
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
                Spacer()
                Text(calorieGoalStatus(current: vm.todayTotals.caloriesKcal, goal: target.caloriesKcal))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int(vm.todayTotals.caloriesKcal.rounded()))")
                        .font(.system(size: todayCalorieFontSize, weight: .bold))
                        .foregroundStyle(Design.Color.ink)
                        .monospacedDigit()
                    Text("/ \(Int(target.caloriesKcal.rounded())) kcal")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.muted)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(Int(vm.todayTotals.caloriesKcal.rounded())) of \(Int(target.caloriesKcal.rounded())) kilocalories"
                )
                goalBar(
                    current: vm.todayTotals.caloriesKcal,
                    goal: target.caloriesKcal,
                    color: Design.Color.accentSecondary
                )
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 14) {
                    macroMetric("Protein", vm.todayTotals.proteinG, target.proteinG, Design.Color.ringProtein)
                    macroMetric("Carbs", vm.todayTotals.carbsG, target.carbsG, Design.Color.ringCarb)
                    macroMetric("Fat", vm.todayTotals.fatG, target.fatG, Design.Color.ringFat)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    macroMetric("Protein", vm.todayTotals.proteinG, target.proteinG, Design.Color.ringProtein)
                    macroMetric("Carbs", vm.todayTotals.carbsG, target.carbsG, Design.Color.ringCarb)
                    macroMetric("Fat", vm.todayTotals.fatG, target.fatG, Design.Color.ringFat)
                }
            }
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
    }

    private var selectedLocalDay: String {
        SupabaseService().localDayString(
            for: vm.currentDay,
            timezone: vm.profile?.timezone ?? profile.timezone
        )
    }

    private var selectedWeightCheckIn: WeightCheckIn? {
        weightCheckIns.first { $0.localDay == selectedLocalDay }
    }

    private var previousWeightCheckIn: WeightCheckIn? {
        weightCheckIns.first { $0.localDay < selectedLocalDay }
    }

    private var weightCheckInCard: some View {
        Button {
            isShowingWeightCheckIn = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: selectedWeightCheckIn == nil ? "scalemass" : "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(
                        selectedWeightCheckIn == nil
                            ? Design.Color.accentSecondary
                            : Design.Color.success
                    )
                    .frame(width: 42, height: 42)
                    .background(Design.Color.elevated, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedWeightCheckIn == nil ? "Morning check-in" : weightHeadline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    Text(weightDetail)
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if isLoadingWeightCheckIns {
                    ProgressView().tint(Design.Color.accentSecondary)
                } else {
                    Text(selectedWeightCheckIn == nil ? "Log" : "Edit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.accentSecondary)
                }
            }
            .padding(16)
            .background(
                Design.Color.glassFill,
                in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Logs weight with optional mirror and scale photos")
    }

    private var weightHeadline: String {
        guard let checkIn = selectedWeightCheckIn else { return "Morning check-in" }
        let units = vm.profile?.units ?? profile.units
        let value = WeightCheckInPolicy.displayedValue(kilograms: checkIn.weightKG, units: units)
        return "\(String(format: "%.1f", value)) \(units.lowercased() == "imperial" ? "lb" : "kg")"
    }

    private var weightDetail: String {
        guard let checkIn = selectedWeightCheckIn else {
            return "Log your weight and optionally add mirror or scale photos."
        }
        let photoText = checkIn.hasPhotos ? " · photos saved" : ""
        guard let previous = previousWeightCheckIn else { return "First recorded check-in\(photoText)" }
        let units = vm.profile?.units ?? profile.units
        let deltaKG = checkIn.weightKG - previous.weightKG
        let delta =
            units.lowercased() == "imperial"
            ? deltaKG * WeightCheckInPolicy.poundsPerKilogram
            : deltaKG
        let suffix = units.lowercased() == "imperial" ? "lb" : "kg"
        let direction = delta > 0 ? "+" : ""
        return
            "\(direction)\(String(format: "%.1f", delta)) \(suffix) since \(previous.localDay)\(photoText)"
    }

    @MainActor
    private func loadWeightCheckIns() async {
        isLoadingWeightCheckIns = true
        defer { isLoadingWeightCheckIns = false }
        weightCheckIns = (try? await SupabaseService().fetchWeightCheckIns(limit: 60)) ?? []
    }

    private func macroMetric(_ label: String, _ value: Double, _ goal: Double, _ color: Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(value.rounded()))")
                    .font(.system(.subheadline, design: .default, weight: .bold))
                    .foregroundStyle(Design.Color.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: value)
                Text("/\(Int(goal.rounded()))g")
                    .font(.caption2)
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
            }
            goalBar(current: value, goal: goal, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label), \(Int(value.rounded())) of \(Int(goal.rounded())) grams"
        )
    }

    private func goalBar(current: Double, goal: Double, color: Color) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Design.Color.rule)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(
                            width: geometry.size.width
                                * NutritionProgressPolicy.progress(current: current, goal: goal)
                        )
                }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func calorieGoalStatus(current: Double, goal: Double) -> String {
        let difference = Int(abs(goal - current).rounded())
        if current > goal {
            return "\(difference) kcal over"
        }
        if difference == 0 { return "Goal met" }
        return "\(difference) kcal left"
    }

    @ViewBuilder
    private var mealList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Meals")
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
                Spacer()
                if vm.hasProcessingEntries {
                    Text("Working")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.accentSecondary)
                        .shimmering()
                }
            }
            .padding(.bottom, 5)

            if vm.isLoadingDay {
                loadingRows
            } else if vm.entries.isEmpty {
                emptyState
            } else {
                // The server caps a day at 30 meals, so eagerly materializing this
                // small list keeps off-screen rows available to VoiceOver and UI
                // automation even at accessibility text sizes.
                VStack(spacing: 0) {
                    ForEach(Array(vm.entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .center, spacing: 8) {
                            if entry.status == .complete {
                                NavigationLink {
                                    entryDetailDestination(for: entry)
                                } label: {
                                    EntryCard(
                                        entry: entry,
                                        animateCompletion: vm.completionRevealEntryIds.contains(entry.id),
                                        onCompletionRevealFinished: {
                                            vm.consumeCompletionReveal(for: entry.id)
                                        }
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                EntryCard(
                                    entry: entry,
                                    isRetrying: vm.resumingEntryIds.contains(entry.id),
                                    onRetry: entry.canRetry
                                        ? {
                                            Task { await vm.retryEntry(entry) }
                                        } : nil
                                )
                            }

                            if entry.canDelete {
                                deleteButton(for: entry)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if entry.status == .complete,
                            let failureMessage = vm.failedCorrections[entry.id]
                        {
                            CorrectionRetryBanner(
                                message: failureMessage,
                                onRetry: { vm.retryCorrection(entryId: entry.id) },
                                onDismiss: { vm.dismissFailedCorrection(entryId: entry.id) }
                            )
                            .padding(.bottom, 11)
                        }

                        if index < vm.entries.count - 1 {
                            Rectangle()
                                .fill(Design.Color.rule)
                                .frame(height: 0.5)
                                .padding(.leading, entry.imageURL == nil ? 0 : entryThumb + 10)
                        }
                    }
                }
            }
        }
    }

    private var loadingRows: some View {
        VStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 12) {
                    if index == 0 {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Design.Color.elevated)
                            .frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Design.Color.elevated).frame(width: 150, height: 10)
                        Capsule().fill(Design.Color.elevated).frame(width: 210, height: 8)
                    }
                    Spacer()
                }
                .shimmering()
            }
        }
        .padding(.vertical, 12)
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { entryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { entryPendingDeletion = nil }
            }
        )
    }

    private func deleteButton(for entry: Entry) -> some View {
        Button {
            entryPendingDeletion = entry
        } label: {
            Image(systemName: "trash")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete meal: " + entry.summary)
        .accessibilityHint("Asks for confirmation before removing this meal")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "fork.knife")
                .font(.title2)
                .foregroundStyle(Design.Color.accentPrimary)
            Text("Nothing logged yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
            Text("Speak, add a photo, or leave a quick note.")
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var captureDock: some View {
        HStack(spacing: 12) {
            Button {
                openComposer(autoStartRecording: true)
            } label: {
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Design.Color.accentPrimary, in: Circle())
                    .shadow(color: Design.Color.accentPrimary.opacity(0.28), radius: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick voice meal")

            Button {
                openComposer(autoStartRecording: false)
            } label: {
                Label("Log meal", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    private var dayTitle: String {
        vm.isPinnedToToday ? "Today" : weekdayFormatter.string(from: vm.currentDay)
    }

    private var shortDate: String { dateFormatter.string(from: vm.currentDay) }

    private var dayFormatters: DayFormatterCache {
        formatterCache.resolved(for: vm.profile?.timezone ?? profile.timezone)
    }

    private var calendar: Calendar { dayFormatters.calendar }

    private var weekdayFormatter: DateFormatter { dayFormatters.weekdayFormatter }

    private var dateFormatter: DateFormatter { dayFormatters.dateFormatter }

    private func shiftDay(_ delta: Int) {
        guard let candidate = calendar.date(byAdding: .day, value: delta, to: vm.currentDay),
            calendar.compare(candidate, to: Date(), toGranularity: .day) != .orderedDescending
        else { return }
        Task { await vm.load(day: candidate) }
    }

    private var daySwipeIsEnabled: Bool {
        !vm.isPresentingComposer
            && !isShowingAccount
            && !isShowingDatePicker
            && !isShowingWeightCheckIn
    }

    private func daySwipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($daySwipePreview) { value, preview, _ in
                let startsAtRightEdge =
                    DayEdgeSwipePolicy.originatingEdge(
                        startX: value.startLocation.x,
                        containerWidth: containerWidth
                    ) == .right
                guard !(vm.isPinnedToToday && startsAtRightEdge) else {
                    preview = 0
                    return
                }
                preview = DayEdgeSwipePolicy.previewOffset(
                    startX: value.startLocation.x,
                    translation: value.translation,
                    containerWidth: containerWidth
                )
            }
            .onEnded { value in
                guard daySwipeIsEnabled,
                    let delta = DayEdgeSwipePolicy.dayDelta(
                        startX: value.startLocation.x,
                        translation: value.translation,
                        predictedEndTranslation: value.predictedEndTranslation,
                        containerWidth: containerWidth
                    ),
                    !(delta > 0 && vm.isPinnedToToday)
                else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                shiftDay(delta)
            }
    }

    private func openComposer(autoStartRecording: Bool) {
        Perf.mark(autoStartRecording ? "mic.tap" : "compose.tap")
        composerAutoStartsRecording = autoStartRecording
        // Warm the microphone right at the tap so permission checks, session
        // activation, and recorder start run concurrently with the sheet
        // animation — the user can begin speaking before the sheet settles.
        // Skipped when another sheet could delay the composer's presentation;
        // the composer's own fallback start covers that path, and a dismissal
        // mid-warm-up aborts through the composer's onDisappear discard.
        if autoStartRecording, !isShowingAccount, !isShowingDatePicker {
            let recorder = composerAudioHolder.value
            Task { _ = await recorder.startRecording() }
        }
        vm.isPresentingComposer = true
    }

    private func handleCaptureRequest(_ request: AppRouter.CaptureRequest?) {
        guard let request else { return }
        openComposer(autoStartRecording: request.autoStartRecording)
        router.consume(request)
    }
}

/// Shown under a meal whose estimate update failed: the previous estimate is
/// back on the card, and the preserved correction can be retried or let go
/// without retyping or re-recording anything.
private struct CorrectionRetryBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                failureText
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                failureText
                HStack(spacing: 10) {
                    actions
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var failureText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(EntryCorrectionPresentation.failureHeadline)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.danger)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onRetry) {
            Label("Retry", systemImage: "arrow.clockwise")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Design.Color.accentSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 10)
                .background(
                    Design.Color.accentPrimary.opacity(0.12),
                    in: Capsule()
                )
                // ~44pt tap target beyond the visual pill.
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Retry meal update")

        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Design.Color.muted)
                .frame(width: 30, height: 30)
                .background(Design.Color.glassFill, in: Circle())
                .contentShape(Circle().inset(by: -7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss update failure")
        .accessibilityHint("Discards the correction")
    }
}

/// The account button's avatar. Settings owns uploading and caching the
/// photo; this reuses the same disk cache first and falls back to one
/// network fetch, so the corner stays a generic symbol only when the user
/// has no photo (or a transient fetch fails — the next appearance retries).
private struct AccountAvatarIcon: View {
    let userId: String
    let avatarPath: String?
    @State private var avatar: UIImage?

    var body: some View {
        Group {
            if let avatar {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(
                            Design.Color.rule,
                            lineWidth: Design.Stroke.hairline
                        )
                    )
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(Design.Color.muted)
            }
        }
        .task(id: avatarPath) { await loadAvatar() }
    }

    private func loadAvatar() async {
        guard let avatarPath else {
            avatar = nil
            return
        }
        if let cached = ProfilePhotoCache.load(userId: userId, expectedPath: avatarPath),
            let image = UIImage(data: cached)
        {
            avatar = image
            return
        }
        do {
            let data = try await SupabaseService().fetchProfilePhoto(path: avatarPath)
            guard let image = UIImage(data: data) else { return }
            avatar = image
            ProfilePhotoCache.save(data, userId: userId, path: avatarPath)
        } catch {
            // Keep the symbol; Settings and later appearances retry the fetch.
        }
    }
}

/// DateFormatter setup is expensive and body reads these on every render, so
/// hold the instances in @State and rebuild only when the timezone changes.
private final class DayFormatterCache {
    private(set) var calendar = Calendar(identifier: .gregorian)
    private(set) var weekdayFormatter = DateFormatter()
    private(set) var dateFormatter = DateFormatter()
    private var timezoneIdentifier: String?

    func resolved(for timezoneIdentifier: String) -> DayFormatterCache {
        guard timezoneIdentifier != self.timezoneIdentifier else { return self }
        self.timezoneIdentifier = timezoneIdentifier
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneIdentifier) ?? .autoupdatingCurrent
        weekdayFormatter.calendar = calendar
        weekdayFormatter.timeZone = calendar.timeZone
        weekdayFormatter.dateFormat = "EEEE"
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "MMM d"
        return self
    }
}
