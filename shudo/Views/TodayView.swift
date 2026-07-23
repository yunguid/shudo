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
              horizontal >= vertical * horizontalDominance else { return nil }

        let directionMatchesEdge = switch edge {
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
              abs(translation.width) > abs(translation.height) * 1.1 else { return 0 }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm: TodayViewModel
    @ObservedObject private var router = AppRouter.shared

    @State private var isShowingAccount = false
    @State private var isShowingDatePicker = false
    @State private var composerAutoStartsRecording = false
    @State private var showErrorAlert = false
    @State private var entryPendingDeletion: Entry?
    @GestureState private var daySwipePreview: CGFloat = 0

    init(profile: Profile) {
        self.profile = profile
        loadsRemotely = true
        _vm = StateObject(wrappedValue: TodayViewModel(
            profile: profile,
            api: APIService(
                supabaseUrl: AppConfig.supabaseURL,
                supabaseAnonKey: AppConfig.supabaseAnonKey,
                sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
            )
        ))
    }

    init(profile: Profile, previewViewModel: TodayViewModel) {
        self.profile = profile
        loadsRemotely = false
        _vm = StateObject(wrappedValue: previewViewModel)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    AppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            dayNavigator
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
                    Button { isShowingAccount = true } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(Design.Color.muted)
                    }
                    .accessibilityLabel("Account")
                }
            }
            .safeAreaInset(edge: .bottom) { captureDock }
        }
        .sheet(isPresented: $vm.isPresentingComposer) {
            let capturedDay = vm.currentDay
            EntryComposerView(
                selectedDay: capturedDay,
                timezone: vm.profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier,
                autoStartRecording: composerAutoStartsRecording
            ) { text, audio, image, clientRequestId in
                await vm.submitEntry(
                    text: text,
                    audioData: audio,
                    image: image,
                    for: capturedDay,
                    clientRequestId: clientRequestId
                )
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .sheet(isPresented: $isShowingAccount) {
            NavigationStack {
                AccountView(initialProfile: vm.profile ?? profile) { updatedProfile in
                    vm.applyProfile(updatedProfile)
                }
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .entryReanalysisRequested)) { notification in
            guard loadsRemotely else { return }
            guard let entryId = notification.object as? UUID else {
                Task { await vm.load(day: vm.currentDay) }
                return
            }
            vm.beginEntryCorrection(entryId: entryId)
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

            Button { isShowingDatePicker = true } label: {
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
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int(vm.todayTotals.caloriesKcal.rounded()))")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Design.Color.ink)
                        .monospacedDigit()
                    Text("/ \(Int(target.caloriesKcal.rounded())) kcal")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.muted)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
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
        .background(Design.Color.glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func macroMetric(_ label: String, _ value: Double, _ goal: Double, _ color: Color) -> some View {
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
                LazyVStack(spacing: 0) {
                    ForEach(Array(vm.entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .center, spacing: 8) {
                            if entry.status == .complete {
                                NavigationLink {
                                    EntryDetailView(entryId: entry.id)
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
                                    onRetry: entry.canRetry ? {
                                        Task { await vm.retryEntry(entry) }
                                    } : nil
                                )
                            }

                            if entry.canDelete {
                                deleteButton(for: entry)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if index < vm.entries.count - 1 {
                            Rectangle()
                                .fill(Design.Color.rule.opacity(0.65))
                                .frame(height: 0.5)
                                .padding(.leading, entry.imageURL == nil ? 0 : 54)
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
        Button { entryPendingDeletion = entry } label: {
            Image(systemName: "trash")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.muted)
                .frame(width: 40, height: 44)
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
            Button { openComposer(autoStartRecording: true) } label: {
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Design.Color.accentPrimary, in: Circle())
                    .shadow(color: Design.Color.accentPrimary.opacity(0.28), radius: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick voice meal")

            Button { openComposer(autoStartRecording: false) } label: {
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
        .background(.clear)
    }

    private var dayTitle: String {
        vm.isPinnedToToday ? "Today" : weekdayFormatter.string(from: vm.currentDay)
    }

    private var shortDate: String { dateFormatter.string(from: vm.currentDay) }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: vm.profile?.timezone ?? profile.timezone) ?? .autoupdatingCurrent
        return calendar
    }

    private var weekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        return formatter
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private func shiftDay(_ delta: Int) {
        guard let candidate = calendar.date(byAdding: .day, value: delta, to: vm.currentDay),
              calendar.compare(candidate, to: Date(), toGranularity: .day) != .orderedDescending else { return }
        Task { await vm.load(day: candidate) }
    }

    private var daySwipeIsEnabled: Bool {
        !vm.isPresentingComposer && !isShowingAccount && !isShowingDatePicker
    }

    private func daySwipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($daySwipePreview) { value, preview, _ in
                let startsAtRightEdge = DayEdgeSwipePolicy.originatingEdge(
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
                      !(delta > 0 && vm.isPinnedToToday) else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                shiftDay(delta)
            }
    }

    private func openComposer(autoStartRecording: Bool) {
        composerAutoStartsRecording = autoStartRecording
        vm.isPresentingComposer = true
    }

    private func handleCaptureRequest(_ request: AppRouter.CaptureRequest?) {
        guard let request else { return }
        openComposer(autoStartRecording: request.autoStartRecording)
        router.consume(request)
    }
}
