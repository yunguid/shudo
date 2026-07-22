import SwiftUI

struct TodayView: View {
    let profile: Profile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm: TodayViewModel
    @ObservedObject private var router = AppRouter.shared

    @State private var isShowingAccount = false
    @State private var isShowingDatePicker = false
    @State private var composerAutoStartsRecording = false
    @State private var showErrorAlert = false
    @State private var entryPendingDeletion: Entry?

    init(profile: Profile) {
        self.profile = profile
        _vm = StateObject(wrappedValue: TodayViewModel(
            profile: profile,
            api: APIService(
                supabaseUrl: AppConfig.supabaseURL,
                supabaseAnonKey: AppConfig.supabaseAnonKey,
                sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
            )
        ))
    }

    var body: some View {
        NavigationStack {
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
                .refreshable { await vm.load(day: vm.currentDay) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("shudo")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Design.Color.ink)
                }
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
            Task { await vm.loadFor(profile: updated) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await vm.reconcileAfterActivation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await vm.reconcileAfterActivation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .entryReanalysisRequested)) { _ in
            Task { await vm.load(day: vm.currentDay) }
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
            Text("This action cannot be undone.")
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
        Button {
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
                        .font(.system(size: 32, weight: .bold, design: .rounded))
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

            HStack(alignment: .top, spacing: 12) {
                macroMetric("Protein", vm.todayTotals.proteinG, target.proteinG, Design.Color.ringProtein)
                macroMetric("Carbs", vm.todayTotals.carbsG, target.carbsG, Design.Color.ringCarb)
                macroMetric("Fat", vm.todayTotals.fatG, target.fatG, Design.Color.ringFat)
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
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
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
                        HStack(spacing: 2) {
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
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Design.Color.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete entry")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
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
                Image(systemName: "waveform")
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
