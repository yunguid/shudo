import SwiftUI
import UIKit

enum TodayRoute: Hashable {
    enum ZoomSource: String, Hashable { case thread, ledger }

    case meal(UUID, from: ZoomSource)
    case activity(UUID)
    case insights

    static func zoomID(_ id: UUID, from source: ZoomSource) -> String {
        "\(source.rawValue)-\(id.uuidString)"
    }
}

/// What Today needs from the shell.
struct TodayScreenActions {
    var openSettings: () -> Void
    var openBio: () -> Void
    var switchTab: (AppTab) -> Void
    var sendToCoach: (String) -> Void
    /// Targets/goal changed server-side (goal card): refresh the profile.
    var refreshProfile: () -> Void
}

struct TodayScreenEnvironment {
    var loadsRemotely: Bool
    var previewEntryDetail: SupabaseService.EntryDetail?
    var coachMediaURL: (String) async -> URL?
    var trainService: any TrainServing
    var bodyService: any BodyServicing
    var makeInsights: (Profile) -> AnyView
    var now: () -> Date
}

/// Today: the day's coach thread under a pinned macro header. Coach texts,
/// Luke's replies, his meals (streaming receipts), workouts and the body
/// check-in, in time order, iMessage-style. Opens at the bottom; edge-swipe
/// or the calendar walks back through past days, which read as a diary.
struct TodayScreen: View {
    let profile: Profile
    @ObservedObject var today: TodayViewModel
    @ObservedObject var coach: CoachViewModel
    @ObservedObject var context: TodayDayContext
    @ObservedObject var logging: ActivityLoggingController
    let environment: TodayScreenEnvironment
    let actions: TodayScreenActions
    @Binding var headerExpanded: Bool
    var isActiveTab: Bool

    @StateObject private var photoLoader: BodyPhotoLoader
    @State private var formatterCache = DayFormatterCache()
    @State private var path = NavigationPath()
    @State private var pendingDeletion: Entry?
    @State private var deletionTask: Task<Void, Never>?
    @State private var isShowingDatePicker = false
    @State private var highlightedRowId: String?
    @State private var settledDay: String?
    /// Stick-to-bottom: true while the newest row is in view. Only Luke's own
    /// scrolling unpins it; the keyboard and composer resizing never do.
    @State private var isPinnedToBottom = true
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var coachNotice: String?
    @State private var showErrorAlert = false
    @State private var nudgeRescheduleTask: Task<Void, Never>?
    @Namespace private var zoomNamespace
    @GestureState private var daySwipePreview: CGFloat = 0
    /// The new day sliding in like a shoji panel: a short offset (sign =
    /// direction of travel through the diary) and a fade, both settling to 0.
    @State private var dayEntrance: CGFloat = 0
    @State private var dayVeil: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.captureComposerInset) private var composerInset

    init(
        profile: Profile,
        today: TodayViewModel,
        coach: CoachViewModel,
        context: TodayDayContext,
        logging: ActivityLoggingController,
        environment: TodayScreenEnvironment,
        actions: TodayScreenActions,
        headerExpanded: Binding<Bool>,
        isActiveTab: Bool
    ) {
        self.profile = profile
        self.today = today
        self.coach = coach
        self.context = context
        self.logging = logging
        self.environment = environment
        self.actions = actions
        _headerExpanded = headerExpanded
        self.isActiveTab = isActiveTab
        _photoLoader = StateObject(wrappedValue: BodyPhotoLoader(service: environment.bodyService))
    }

    // MARK: Derived state

    private var currentProfile: Profile { today.profile ?? profile }
    private var formatters: DayFormatterCache { formatterCache.resolved(for: currentProfile.timezone) }
    private var selectedDay: String { formatters.localDayFormatter.string(from: today.currentDay) }
    private var todayDay: String { formatters.localDayFormatter.string(from: environment.now()) }
    private var isToday: Bool { selectedDay >= todayDay }
    private var units: String { currentProfile.units }

    private var hiddenIds: Set<String> {
        guard let pendingDeletion else { return [] }
        return [DayThreadItem.meal(pendingDeletion).id]
    }

    private var headerTotals: DayTotals {
        DayHeaderMath.totals(today.todayTotals, excluding: pendingDeletion.map { [$0] } ?? [])
    }

    /// The selected day's meals. While another day's meals are still in the
    /// model (a new day loading), they stay out of this day's thread.
    private var dayMeals: [Entry] {
        today.entries
            .filter { $0.id != pendingDeletion?.id && ($0.localDay ?? selectedDay) == selectedDay }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var dayActivities: [Activity] {
        guard context.localDay == selectedDay else { return [] }
        return context.activities(overlay: Array(logging.overlay.values))
    }

    private var threadItems: [DayThreadItem] {
        let showsCoach = coach.localDay == selectedDay
        return DayThreadPolicy.merge(
            messages: showsCoach ? coach.messages : [],
            pending: coach.pendingSends.filter { $0.localDay == selectedDay },
            entries: dayMeals,
            activities: dayActivities,
            checkIn: context.checkIns.first { $0.localDay == selectedDay },
            typing: showsCoach ? coach.typing : nil,
            now: environment.now(),
            hiddenIds: hiddenIds
        )
    }

    private var phaseDayLabel: String? {
        DayLabelPolicy.phaseDay(
            localDay: selectedDay,
            goalStartedOn: context.goal?.goalStartedOn,
            goalType: context.goal?.goalType ?? currentProfile.goalType
        )
    }

    private var isTyping: Bool { coach.typing != nil && coach.localDay == selectedDay }

    /// The day the header's numbers describe. While a new day loads, the
    /// old day's meals — and so its totals — are still on screen, so the
    /// figure and its label stay that day's (dimmed) until the new day's
    /// meals land; then number and label hand off together. Never "855"
    /// from one day under "kcal short" from another.
    private var figureDay: String {
        guard today.isLoadingDay, let shown = today.entries.first?.localDay else { return selectedDay }
        return shown
    }

    // MARK: Body

    var body: some View {
        let rows = DayThreadPolicy.rows(for: threadItems)
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        thread(rows, viewport: geometry.size.height)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .scrollDismissesKeyboard(.interactively)
                    // The keyboard composer floats over the thread; make room
                    // for it so the newest row sits right above it.
                    .safeAreaPadding(.bottom, composerInset)
                    .onScrollPhaseChange { _, phase in
                        scrollPhase = phase
                        // Going back to reading slides the open day panel
                        // shut, the way a shoji closes behind you.
                        if phase == .interacting, headerExpanded {
                            withAnimation(Design.Motion.calm(Design.Motion.shoji, reduceMotion: reduceMotion)) {
                                headerExpanded = false
                            }
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self, of: Self.isAtBottom) { _, atBottom in
                        if atBottom {
                            isPinnedToBottom = true
                        } else if scrollPhase.isUserDriven {
                            isPinnedToBottom = false
                        }
                    }
                    .offset(x: daySwipePreview + dayEntrance)
                    .opacity(1 - dayVeil)
                    .refreshable {
                        guard environment.loadsRemotely else { return }
                        await reloadDay()
                    }
                    .onChange(of: selectedDay) { previous, day in
                        slideIn(day: day, from: previous)
                        Task { await coach.refresh(day: day) }
                        Task { await context.load(localDay: day) }
                        settledDay = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            proxy.scrollTo("thread.bottom", anchor: .bottom)
                            try? await Task.sleep(for: .milliseconds(500))
                            settledDay = day
                        }
                    }
                    .onChange(of: coach.focusedMessageId) { _, id in
                        guard let id else { return }
                        focus(on: id, proxy: proxy)
                    }
                    .onAppear {
                        if let id = coach.focusedMessageId { focus(on: id, proxy: proxy) }
                        #if DEBUG
                        previewScroll(proxy: proxy)
                        #endif
                    }
                    .onChange(of: rows.last?.id) { _, _ in
                        guard settledDay == selectedDay else { return }
                        // Don't yank Luke away from something he scrolled up
                        // to read, unless the new row is his own send.
                        guard isPinnedToBottom || rows.last?.item.side == .me else { return }
                        isPinnedToBottom = true
                        withAnimation(Design.Motion.gated(Design.Motion.arrive, reduceMotion: reduceMotion)) {
                            proxy.scrollTo("thread.bottom", anchor: .bottom)
                        }
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(daySwipeGesture(containerWidth: geometry.size.width))
            }
            .background { AppBackground() }
            // The header is the page's own top (no nav bar, no glass card):
            // the day's name, the figure, and the account at the corner.
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .overlay(alignment: .bottom) { bottomOverlay }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: TodayRoute.self) { route in destination(route) }
        }
        // Haptics only where something landed: Shudo's reply, a delete.
        .sensoryFeedback(trigger: lastCoachMessageId) { _, _ in
            isActiveTab && isToday ? .impact(flexibility: .soft, intensity: 0.5) : nil
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: pendingDeletion?.id)
        .task {
            settledDay = selectedDay
            if context.localDay != selectedDay { await context.load(localDay: selectedDay) }
            if coach.localDay != selectedDay { await coach.refresh(day: selectedDay) }
        }
        .task(id: readKey) {
            guard isActiveTab, scenePhase == .active else { return }
            await coach.markVisibleRead()
        }
        .onChange(of: coach.localDay) { _, day in
            // Sending from a past day jumps the thread back to today.
            if day != selectedDay { select(day: day) }
        }
        .onChange(of: today.entries) { _, _ in
            context.scheduleWeekRefresh()
            rescheduleDayNudges()
        }
        .onChange(of: coach.errorMessage) { _, message in
            guard let message else { return }
            show(notice: message)
        }
        .onChange(of: today.errorMessage) { _, message in showErrorAlert = message != nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { commitPendingDeletion() }
            if phase == .active { rescheduleDayNudges() }
        }
        .alert("Couldn’t finish that", isPresented: $showErrorAlert) {
            Button("OK") { today.errorMessage = nil }
        } message: {
            Text(today.errorMessage ?? "Please try again.")
        }
    }

    /// Within a thumb's width of the newest row, measured above every bottom
    /// inset (tab bar, keyboard, composer). `visibleRect` spans the insets.
    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
        return geometry.contentSize.height - visibleBottom <= 48
    }

    private var readKey: String {
        "\(isActiveTab)|\(scenePhase == .active)|\(coach.localDay)|\(coach.messages.count)"
    }

    private var lastCoachMessageId: UUID? {
        coach.messages.last { $0.role == .coach }?.id
    }

    // MARK: Header

    private var header: some View {
        let numbers = DayHeaderMath.numbers(totals: headerTotals, target: today.effectiveTarget)
        return DayHeader(
            expanded: $headerExpanded,
            isPickingDay: $isShowingDatePicker,
            title: threadDayName,
            subtitle: titleSubtitle,
            subtitleIsLive: isTyping,
            numbers: numbers,
            totals: headerTotals,
            target: today.effectiveTarget,
            weekDays: WeekStripPolicy.days(
                selectedDay: selectedDay,
                today: todayDay,
                totals: context.dayTotals,
                targetHistory: context.targetHistory,
                fallbackTarget: today.effectiveTarget,
                selectedTotals: headerTotals
            ),
            meals: dayMeals,
            timeText: timeText,
            onSelectDay: { select(day: $0) },
            onOpenMeal: { meal in
                guard meal.status == .complete else { return }
                path.append(TodayRoute.meal(meal.id, from: .ledger))
            },
            onDeleteMeal: beginDeletion,
            onOpenInsights: { path.append(TodayRoute.insights) },
            zoomNamespace: zoomNamespace,
            isPast: figureDay < todayDay,
            figureDay: figureDay,
            isSettling: figureDay != selectedDay,
            account: { accountButton },
            dayPicker: { datePicker }
        )
    }

    // MARK: Thread

    @ViewBuilder
    private func thread(_ rows: [DayThreadRow], viewport: CGFloat) -> some View {
        let receiptRowId = DayThreadPolicy.readReceiptRowId(for: rows)
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                if today.isLoadingDay || coach.isLoading {
                    loadingRows
                } else {
                    emptyState
                        .frame(minHeight: viewport * 0.6)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, isFirst: index == 0, showsReceipt: row.id == receiptRowId)
                    .padding(.top, Self.spacing(above: row, after: index > 0 ? rows[index - 1] : nil))
                    .id(row.id)
                    .transition(arrival(for: row.item.side))
            }
            // The bottom margin *is* the scroll target, so scrolling to the
            // newest row keeps the same breathing room above the capture bar
            // as opening the day does.
            Color.clear.frame(height: 18).id("thread.bottom")
        }
        .animation(
            settledDay == selectedDay ? Design.Motion.gated(Design.Motion.arrive, reduceMotion: reduceMotion) : nil,
            value: rows.map(\.id)
        )
    }

    /// Messages rhythm: tight within a burst, a breath between speakers,
    /// real ma between chapters. Bubbles in a run sit 3pt apart, anything
    /// with a card 8pt, a new speaker 18pt; a timestamp brings its own room.
    static func spacing(above row: DayThreadRow, after previous: DayThreadRow?) -> CGFloat {
        guard let previous, row.timestamp == nil else { return 0 }
        if row.startsGroup { return 18 }
        return isPlainBubble(previous.item) && isPlainBubble(row.item) ? 3 : 8
    }

    /// A text bubble with nothing hanging off it.
    static func isPlainBubble(_ item: DayThreadItem) -> Bool {
        switch item {
        case .pending, .typing:
            return true
        case .message(let message):
            guard item.isBubble else { return false }
            switch message.payload {
            case .none, .mealAck, .unknown: return true
            default: return false
            }
        case .meal, .activity, .checkIn:
            return false
        }
    }

    /// New rows settle like ink on paper (a soft blur clearing, a small
    /// rise); leaving rows simply fade.
    private func arrival(for side: ThreadSide) -> AnyTransition {
        .asymmetric(insertion: .ink(reduceMotion: reduceMotion), removal: .opacity)
    }

    /// "Today", "Yesterday", "Monday", "Mon, Sep 28".
    private var threadDayName: String {
        DayLabelPolicy.threadDay(localDay: selectedDay, today: todayDay)
    }

    @ViewBuilder
    private func rowView(_ row: DayThreadRow, isFirst: Bool, showsReceipt: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let timestamp = row.timestamp {
                // The header already names the day; the stamp keeps only
                // the time (VoiceOver still hears the day on the first).
                ThreadTimestamp(time: timeText(timestamp))
                    .accessibilityLabel(isFirst ? "\(threadDayName), \(timeText(timestamp))" : timeText(timestamp))
                    .accessibilityAddTraits(isFirst ? .isHeader : [])
            }
            Group {
                switch row.item {
                case .message(let message): messageRow(message, row: row)
                case .pending(let pending): pendingRow(pending, row: row)
                case .meal(let entry): mealRow(entry)
                case .activity(let activity): activityRow(activity)
                case .checkIn(let checkIn): checkInRow(checkIn)
                case .typing: typingRow
                }
            }
            .background {
                if highlightedRowId == row.id {
                    RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                        .fill(Design.Color.ember.opacity(0.10))
                        .padding(-5)
                        .transition(.opacity)
                }
            }
            if showsReceipt {
                Text("Read")
                    .font(Design.Typeface.meta)
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func messageRow(_ message: CoachMessage, row: DayThreadRow) -> some View {
        switch message.role {
        case .user:
            MeRow {
                VStack(alignment: .trailing, spacing: 4) {
                    if let path = message.attachmentPath {
                        ChatPhoto(path: path, loadURL: environment.coachMediaURL)
                    }
                    if !message.body.isEmpty {
                        MessageBubble(text: message.body, isMine: true, position: row.position)
                    }
                    if let interruption = coach.interruption(forUserMessage: message.id) {
                        interruptionLine(interruption)
                    }
                }
            }
        case .systemEvent:
            Text(message.body)
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        case .coach:
            let hasBody = !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let card = cardView(for: message)
            CoachRow {
                VStack(alignment: .leading, spacing: 6) {
                    if hasBody {
                        MessageBubble(
                            text: message.body,
                            isMine: false,
                            position: card == nil ? row.position : Self.positionBeforeCard(row.position)
                        )
                        .contentTransition(.opacity)
                    }
                    if let card {
                        card.environment(\.threadCardJoinsAbove, hasBody)
                    }
                }
            }
        }
    }

    /// A bubble followed by its own card keeps a tight bottom corner.
    static func positionBeforeCard(_ position: BubblePosition) -> BubblePosition {
        switch position {
        case .single, .first: return .first
        case .middle, .last: return .middle
        }
    }

    private func cardView(for message: CoachMessage) -> AnyView? {
        let cardActions = self.cardActions
        switch message.payload {
        case .plan(let card):
            return AnyView(GamePlanCardView(card: card))
        case .recap(let card):
            let hour = formatters.calendar.component(.hour, from: message.deliverAt)
            return AnyView(RecapCardView(
                card: card,
                eyebrow: ThreadCardCopy.recapEyebrow(card: card, localDay: message.localDay, deliveredHour: hour),
                actions: cardActions
            ))
        case .snackRec(let card):
            return AnyView(SnackRecCardView(
                message: message,
                card: card,
                liftLater: liftLaterToday(after: message.deliverAt),
                actions: cardActions
            ))
        case .trainingPlan(let card):
            return AnyView(TrainingPlanCardView(card: card, actions: cardActions))
        case .goalChange(let card):
            return AnyView(GoalChangeCardView(card: card, units: units, actions: cardActions))
        case .profileUpdate(let card):
            return AnyView(ProfileUpdateCardView(message: message, card: card, actions: cardActions))
        case .workoutAck(let card):
            // The workout's own receipt is right above; only PRs earn a card.
            guard !card.prs.isEmpty else { return nil }
            return AnyView(WorkoutAckCardView(card: card, actions: cardActions))
        case .checkIn(let card):
            // A weigh-in's number is already on his check-in card and in
            // the bubble; only a physique review adds something to read.
            guard card.kind == .photoFeedback, let review = card.review else { return nil }
            return AnyView(PhysiqueReviewCardView(review: review))
        case .mealAck, .none, .unknown:
            return nil
        }
    }

    /// Wording only: a lift is still ahead today (an un-logged activity).
    private func liftLaterToday(after date: Date) -> Bool {
        !dayActivities.contains { $0.kind == .strength && $0.occurredAt > date.addingTimeInterval(-3_600) }
            && isToday
    }

    private var cardActions: ThreadCardActions {
        ThreadCardActions(
            act: { action in await coach.act(on: action) },
            isActing: { id in coach.actionsInFlight.contains(id) },
            send: { text in actions.sendToCoach(text) },
            openTab: actions.switchTab,
            openBio: actions.openBio,
            openActivity: { id in path.append(TodayRoute.activity(id)) },
            targetsChanged: actions.refreshProfile,
            mealLogged: {
                guard environment.loadsRemotely else { return }
                Task { await today.load(day: today.currentDay) }
            }
        )
    }

    private func pendingRow(_ pending: CoachPendingSend, row: DayThreadRow) -> some View {
        MeRow {
            VStack(alignment: .trailing, spacing: 4) {
                if let data = pending.attachmentJPEG, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.bubble, style: .continuous))
                }
                if !pending.text.isEmpty {
                    // A dimmed bubble is the whole "sending" state; it
                    // brightens the moment Shudo has it.
                    MessageBubble(text: pending.text, isMine: true, position: row.position)
                        .opacity(pending.isFailed ? 0.6 : 0.85)
                }
                if case .failed(let message, let retryable) = pending.state {
                    HStack(spacing: 10) {
                        Text(message)
                            .font(Design.Typeface.text(.caption2))
                            .foregroundStyle(Design.Color.danger)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        if retryable {
                            Button("Retry") { coach.retry(pending.clientRequestId) }
                                .font(Design.Typeface.text(.caption, weight: .semibold))
                                .foregroundStyle(Design.Color.ember)
                                .accessibilityLabel("Retry message")
                        }
                        Button("Delete") { coach.discardPending(pending.clientRequestId) }
                            .font(Design.Typeface.text(.caption, weight: .semibold))
                            .foregroundStyle(Design.Color.textSecondary)
                            .accessibilityLabel("Delete unsent message")
                    }
                }
            }
        }
    }

    private func interruptionLine(_ interruption: CoachTurnInterruption) -> some View {
        HStack(spacing: 8) {
            Text("Shudo got cut off")
                .font(Design.Typeface.text(.caption2))
                .foregroundStyle(Design.Color.textTertiary)
            if interruption.retryable {
                Button("Ask again") { coach.retry(interruption.clientRequestId) }
                    .font(Design.Typeface.text(.caption, weight: .semibold))
                    .foregroundStyle(Design.Color.ember)
            }
        }
    }

    @ViewBuilder
    private func mealRow(_ entry: Entry) -> some View {
        MeRow {
            VStack(alignment: .trailing, spacing: 6) {
                if entry.status == .complete {
                    NavigationLink(value: TodayRoute.meal(entry.id, from: .thread)) {
                        MealReceiptCard(
                            entry: entry,
                            animateCompletion: today.completionRevealEntryIds.contains(entry.id),
                            onCompletionRevealFinished: { today.consumeCompletionReveal(for: entry.id) }
                        )
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: TodayRoute.zoomID(entry.id, from: .thread), in: zoomNamespace)
                    .contextMenu { mealMenu(entry) }
                } else {
                    MealReceiptCard(
                        entry: entry,
                        isRetrying: today.resumingEntryIds.contains(entry.id),
                        onRetry: entry.canRetry ? { Task { await today.retryEntry(entry) } } : nil
                    )
                    .contextMenu { mealMenu(entry) }
                }
                if entry.status == .complete, let failure = today.failedCorrections[entry.id] {
                    CorrectionRetryBanner(
                        message: failure,
                        onRetry: { today.retryCorrection(entryId: entry.id) },
                        onDismiss: { today.dismissFailedCorrection(entryId: entry.id) }
                    )
                    .frame(width: Design.Layout.threadCardWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func mealMenu(_ entry: Entry) -> some View {
        if entry.status == .complete {
            Button("Open", systemImage: "doc.text.magnifyingglass") {
                path.append(TodayRoute.meal(entry.id, from: .thread))
            }
        }
        if entry.canDelete {
            Button("Delete meal", systemImage: "trash", role: .destructive) { beginDeletion(entry) }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: Activity) -> some View {
        MeRow {
            if activity.isLocalOnly {
                liveActivityCard(activity)
            } else {
                NavigationLink(value: TodayRoute.activity(activity.id)) {
                    if activity.status == .complete, activity.localState == nil {
                        WorkoutReceiptCard(activity: activity, units: units)
                    } else {
                        liveActivityCard(activity)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Sending, reading, failed or unsent: the Train card has those states.
    private func liveActivityCard(_ activity: Activity) -> some View {
        ActivityCard(
            activity: activity,
            units: units,
            onRetry: activity.isNotSent ? { logging.retry(activity.id) } : nil,
            onDiscard: activity.isNotSent ? { logging.discard(activity.id) } : nil
        )
        .frame(width: Design.Layout.threadCardWidth)
    }

    private func checkInRow(_ checkIn: WeightCheckIn) -> some View {
        MeRow {
            CheckInThreadCard(
                checkIn: checkIn,
                dayLabel: phaseDayLabel.map { $0.replacingOccurrences(of: " of the bulk", with: "").replacingOccurrences(of: " of the cut", with: "") },
                units: units,
                photoLoader: photoLoader,
                onOpenBody: { actions.switchTab(.body) }
            )
        }
    }

    private var typingRow: some View {
        CoachRow {
            // Dots only, like Messages; tool status labels read as noise.
            CoachTypingBubble()
        }
    }

    /// A day with nothing in it yet: Shudo's face and a hello. The header
    /// above already says what the day asks for. A past empty day just
    /// says so.
    private var emptyState: some View {
        VStack(spacing: Design.Space.xl) {
            CoachAvatar(size: 56)
                .opacity(isToday ? 1 : 0.45)
            Text(
                isToday
                    ? DayLabelPolicy.greeting(hour: formatters.calendar.component(.hour, from: environment.now()), name: currentProfile.displayName)
                    : "Nothing logged"
            )
            .font(Design.Typeface.display(.title2))
            .foregroundStyle(isToday ? Design.Color.textPrimary : Design.Color.textSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var loadingRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                HStack {
                    if index == 1 { Spacer() }
                    RoundedRectangle(cornerRadius: Design.Radius.bubble, style: .continuous)
                        .fill(Design.Color.surface1)
                        .frame(width: [220, 160, 250][index], height: 40)
                    if index != 1 { Spacer() }
                }
                .modifier(Breathing())
            }
        }
        .padding(.top, 20)
    }

    // MARK: Overlays

    @ViewBuilder
    private var bottomOverlay: some View {
        VStack(spacing: 8) {
            if let coachNotice {
                Text(coachNotice)
                    .font(Design.Typeface.text(.footnote, weight: .medium))
                    .foregroundStyle(Design.Color.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .chromeGlass(in: Capsule(), tint: Design.Color.canvas.opacity(0.6))
                    .transition(.shoji(.bottom, reduceMotion: reduceMotion))
            }
            if let pendingDeletion {
                HStack(spacing: 12) {
                    Text("Deleted “\(pendingDeletion.summary)”")
                        .font(Design.Typeface.text(.footnote, weight: .medium))
                        .foregroundStyle(Design.Color.textPrimary)
                        .lineLimit(1)
                    Button("Undo") { undoDeletion() }
                        .font(Design.Typeface.text(.footnote, weight: .bold))
                        .foregroundStyle(Design.Color.ember)
                        .accessibilityIdentifier("today.undoDelete")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .chromeGlass(in: Capsule(), tint: Design.Color.canvas.opacity(0.6), interactive: true)
                .transition(.shoji(.bottom, reduceMotion: reduceMotion))
            } else if !isToday {
                Button {
                    select(day: todayDay)
                } label: {
                    Label("Back to today", systemImage: "arrow.down.to.line")
                        .font(Design.Typeface.text(.footnote, weight: .semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .chromeGlass(in: Capsule(), tint: Design.Color.canvas.opacity(0.5), interactive: true)
                .transition(.opacity)
            }
        }
        .padding(.bottom, 10)
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: pendingDeletion?.id)
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: coachNotice)
        .animation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion), value: isToday)
    }

    // MARK: Account

    private var accountButton: some View {
        Button(action: actions.openSettings) {
            AccountAvatarIcon(
                userId: currentProfile.userId,
                avatarPath: currentProfile.avatarPath,
                displayName: currentProfile.displayName,
                loadsRemotely: environment.loadsRemotely
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
        .accessibilityHint("Settings and your bio")
    }

    /// "typing…" while Shudo works (never the tool phase), else where that
    /// day sits in the phase ("Day 35 of the bulk"). The title above already
    /// names the day.
    private var titleSubtitle: String? {
        if isTyping { return "typing…" }
        return phaseDayLabel
    }

    private var datePicker: some View {
        DatePicker(
            "Day",
            selection: Binding(
                get: { today.currentDay },
                set: { selected in
                    isShowingDatePicker = false
                    select(day: formatters.localDayFormatter.string(from: selected))
                }
            ),
            in: ...environment.now(),
            displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .tint(Design.Color.ember)
        .frame(width: 320)
        .padding(Design.Space.m)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(_ route: TodayRoute) -> some View {
        switch route {
        case .meal(let id, let source):
            mealDetail(id)
                .navigationTransition(.zoom(sourceID: TodayRoute.zoomID(id, from: source), in: zoomNamespace))
        case .activity(let id):
            activityDetail(id)
        case .insights:
            environment.makeInsights(currentProfile)
        }
    }

    @ViewBuilder
    private func mealDetail(_ id: UUID) -> some View {
        let submit: (EntryCorrectionSubmission) -> Void = { submission in
            _ = today.submitCorrection(entryId: id, submission: submission)
        }
        if let preview = environment.previewEntryDetail {
            EntryDetailView(entryId: id, previewDetail: preview, onCorrectionSubmit: submit)
        } else {
            EntryDetailView(
                entryId: id,
                seed: today.entries.first { $0.id == id },
                onCorrectionSubmit: submit
            )
        }
    }

    @ViewBuilder
    private func activityDetail(_ id: UUID) -> some View {
        if let activity = dayActivities.first(where: { $0.id == id }) {
            ActivityDetailView(
                activity: activity,
                units: units,
                loadImageURL: environment.coachMediaURL,
                onRetry: activity.isNotSent ? { logging.retry(id) } : nil,
                onDelete: {
                    do {
                        try await environment.trainService.deleteActivity(id: id)
                        context.remove(activityId: id)
                        logging.forget(id)
                        return true
                    } catch {
                        return false
                    }
                }
            )
        } else {
            ContentUnavailableView("Workout not found", systemImage: "dumbbell")
        }
    }

    // MARK: Day navigation

    private func select(day: String) {
        guard day <= todayDay, day != selectedDay,
              let date = formatters.date(forLocalDay: day) else { return }
        commitPendingDeletion()
        #if DEBUG
        // Previews have no session: walk days on fixture meals instead of
        // the network (production always loads below).
        if !environment.loadsRemotely {
            let target = day == todayDay ? environment.now() : date
            Task { await today.showPreviewDay(target, entries: ShellPreviewFixtures.entries(forLocalDay: day)) }
            return
        }
        #endif
        if day == todayDay {
            Task { await today.load(day: environment.now()) }
        } else {
            Task { await today.load(day: date) }
        }
    }

    /// The thread for a new day slides in from the side it came from —
    /// earlier days from the left, later from the right — and settles once.
    private func slideIn(day: String, from previous: String) {
        guard !reduceMotion else {
            dayVeil = 1
            withAnimation(Design.Motion.calm(Design.Motion.breath, reduceMotion: true)) { dayVeil = 0 }
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            dayEntrance = day < previous ? -28 : 28
            dayVeil = 1
        }
        withAnimation(Design.Motion.shoji) {
            dayEntrance = 0
            dayVeil = 0
        }
    }

    private func shift(by delta: Int) {
        guard let target = LocalDayMath.adding(delta, to: selectedDay), target <= todayDay else { return }
        select(day: target)
    }

    private func daySwipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($daySwipePreview) { value, preview, _ in
                let startsAtRightEdge = DayEdgeSwipePolicy.originatingEdge(
                    startX: value.startLocation.x,
                    containerWidth: containerWidth
                ) == .right
                guard !(isToday && startsAtRightEdge), path.isEmpty else {
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
                guard path.isEmpty,
                      let delta = DayEdgeSwipePolicy.dayDelta(
                        startX: value.startLocation.x,
                        translation: value.translation,
                        predictedEndTranslation: value.predictedEndTranslation,
                        containerWidth: containerWidth
                      ),
                      !(delta > 0 && isToday)
                else { return }
                shift(by: delta)
            }
    }

    private func reloadDay() async {
        async let meals: Void = today.load(day: today.currentDay)
        async let thread: Void = coach.refresh(day: selectedDay)
        async let extras: Void = context.refreshAll()
        _ = await (meals, thread, extras)
    }

    // MARK: Deep links

    private func focus(on id: UUID, proxy: ScrollViewProxy) {
        let rowId = DayThreadPolicy.rowId(forMessage: id)
        Task { @MainActor in
            // Let a day switch settle so the row exists before scrolling.
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion)) {
                proxy.scrollTo(rowId, anchor: .center)
                highlightedRowId = rowId
            }
            coach.consumeFocus()
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(Design.Motion.settle) {
                if highlightedRowId == rowId { highlightedRowId = nil }
            }
        }
    }

    #if DEBUG
    /// `-shudoTodayScrollRow N` (previews only): park row N at the top so
    /// screenshots can show the morning without a touch driver.
    private func previewScroll(proxy: ScrollViewProxy) {
        let arguments = ProcessInfo.processInfo.arguments
        // `-shudoTodayPicker`: open the day picker for screenshots.
        if arguments.contains("-shudoTodayPicker") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1_200))
                isShowingDatePicker = true
            }
        }
        // `-shudoTodayMotion header|day|reply`: play the unfold, a day switch
        // (and back) on a timer, for frame-by-frame motion review.
        if let flag = arguments.firstIndex(of: "-shudoTodayMotion"), arguments.indices.contains(flag + 1) {
            let kind = arguments[flag + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                if kind == "reply" {
                    // A send and Shudo's streamed answer: watch rows arrive.
                    actions.sendToCoach("what should dinner be?")
                    return
                }
                if kind == "header" {
                    withAnimation(Design.Motion.calm(Design.Motion.shoji, reduceMotion: reduceMotion)) { headerExpanded = true }
                } else {
                    shift(by: -1)
                }
                try? await Task.sleep(for: .seconds(2.5))
                if kind == "header" {
                    withAnimation(Design.Motion.calm(Design.Motion.shoji, reduceMotion: reduceMotion)) { headerExpanded = false }
                } else {
                    select(day: todayDay)
                }
            }
        }
        guard let flag = arguments.firstIndex(of: "-shudoTodayScrollRow"),
              arguments.indices.contains(flag + 1),
              let index = Int(arguments[flag + 1]) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            let rows = DayThreadPolicy.rows(for: threadItems)
            guard rows.indices.contains(index) else { return }
            proxy.scrollTo(rows[index].id, anchor: .top)
        }
    }
    #endif

    // MARK: Delete with undo

    private func beginDeletion(_ entry: Entry) {
        guard entry.canDelete else { return }
        commitPendingDeletion()
        withAnimation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion)) {
            pendingDeletion = entry
        }
        deletionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            commitPendingDeletion()
        }
    }

    private func undoDeletion() {
        deletionTask?.cancel()
        deletionTask = nil
        withAnimation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion)) {
            pendingDeletion = nil
        }
    }

    private func commitPendingDeletion() {
        deletionTask?.cancel()
        deletionTask = nil
        guard let entry = pendingDeletion else { return }
        pendingDeletion = nil
        Task { await today.deleteEntry(entry) }
    }

    // MARK: Misc

    private func timeText(_ date: Date) -> String {
        formatters.timeFormatter.string(from: date)
    }

    private func show(notice message: String) {
        coachNotice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            if coachNotice == message { coachNotice = nil }
            if coach.errorMessage == message { coach.errorMessage = nil }
        }
    }

    /// The offline fallback nudges (coach disabled + the legacy toggle on);
    /// `DayNotificationScheduler` itself no-ops otherwise. Debounced because
    /// status polling touches `entries` every ~650 ms.
    private func rescheduleDayNudges() {
        guard environment.loadsRemotely, isToday,
              UserDefaults.standard.bool(forKey: DayNotificationScheduler.enabledDefaultsKey)
        else { return }
        nudgeRescheduleTask?.cancel()
        let timezone = TimeZone(identifier: currentProfile.timezone) ?? .autoupdatingCurrent
        let loggedMeals = today.entries.filter { $0.status != .failed }
        let nudgeContext = DayNudgeContext(
            now: Date(),
            timezone: timezone,
            totals: today.todayTotals,
            target: today.effectiveTarget,
            loggedMealCount: loggedMeals.count,
            lastMealAt: loggedMeals.map(\.createdAt).max(),
            goalType: currentProfile.goalType,
            targetWeightKG: currentProfile.targetWeightKG,
            units: currentProfile.units,
            weightCheckIns: context.checkIns,
            recentNutrition: context.dayTotals,
            targetHistory: context.targetHistory,
            displayName: currentProfile.displayName
        )
        let weighInSeconds =
            UserDefaults.standard.object(forKey: DayNotificationScheduler.weighInSecondsDefaultsKey) as? Double
            ?? DayNotificationScheduler.defaultWeighInSecondsFromMidnight
        nudgeRescheduleTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await DayNotificationScheduler.reschedule(context: nudgeContext, weighInSecondsFromMidnight: weighInSeconds)
        }
    }
}

/// A photo Luke sent in chat (coach-media, signed on demand).
struct ChatPhoto: View {
    let path: String
    let loadURL: (String) async -> URL?
    @State private var url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Design.Radius.bubble, style: .continuous)
                .fill(Design.Color.surface2)
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                .allowsHitTesting(false)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.bubble, style: .continuous))
        .task(id: path) { url = await loadURL(path) }
        .accessibilityLabel("Photo you sent")
    }
}

private extension ScrollPhase {
    /// Luke's finger (or its fling), as opposed to a programmatic scroll or
    /// an inset change.
    var isUserDriven: Bool {
        switch self {
        case .tracking, .interacting, .decelerating: true
        default: false
        }
    }
}
