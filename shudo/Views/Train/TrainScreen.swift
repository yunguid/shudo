import SwiftUI
import UIKit

struct ActivityRoute: Hashable {
    let id: UUID
}

/// What the workout logger opens with.
struct WorkoutLogContext: Identifiable {
    let id = UUID()
    var session: TrainingSession?
    var targets: [LiftTarget] = []
    var initialKind: ActivityKind?
    var initialImage: UIImage?
}

/// The Train tab, one idea per region and space between them: the week as
/// seven seals, today's session as the one panel (the next session with
/// numbers to beat, or today's once it's logged), the records as a ledger,
/// and the history as a diary. Host it inside a `NavigationStack`
/// (activity detail pushes onto it):
///
///     NavigationStack {
///         TrainScreen(profile: profile, onAskCoach: { coach.compose($0) })
///     }
///
/// `onAskCoach` receives a complete sentence for the coach ("Build me a
/// training plan…") — send it, or prefill the capture bar with it.
/// Logging lives in the command well in the corner (tap to say it, hold for
/// "Log workout" or a photo), so the tab has no "+" and no big Log button —
/// the session panel offers only the quiet typed way. `onLogByVoice` (the
/// shell binds it to the well's recorder in the Train context) backs the
/// panel's VoiceOver "Log by voice" action; unbound, that opens the typed
/// logger.
struct TrainScreen: View {
    @StateObject private var viewModel: TrainViewModel
    var onAskCoach: (String) -> Void
    var onLogByVoice: (() -> Void)?

    @State private var logContext: WorkoutLogContext?
    @State private var planSheet: TrainingPlan?
    @State private var submittedLogs = 0
    @State private var freshRecords = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var dayColumnWidth: CGFloat = 46

    #if DEBUG
    /// PolishPreview only: scroll to an anchor ("prs", "recent", "bottom")
    /// after load. Inside the shell it comes from `-shudoTrainPreview`.
    var previewScrollAnchor: String? = TrainPreviewFixtures.variant.flatMap {
        ["prs", "recent", "bottom"].contains($0) ? $0 : nil
    }
    #endif

    static let buildPlanPrompt =
        "Build me a training plan that fits my week — lean bulk, progressive overload, and make lifting fun again."
    static let changePlanPrompt =
        "I want to change my training plan. Ask me what isn’t working."
    static let changeDraftPrompt =
        "Before I run that new plan, I want to change a few things. Ask me what."

    init(
        viewModel: @autoclosure @escaping () -> TrainViewModel,
        onAskCoach: @escaping (String) -> Void,
        onLogByVoice: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.onAskCoach = onAskCoach
        self.onLogByVoice = onLogByVoice
    }

    /// Convenience for the app shell. Pass a shared `logging` controller so
    /// workouts logged from Today show up here (and vice versa).
    init(
        profile: Profile,
        logging: ActivityLoggingController? = nil,
        onAskCoach: @escaping (String) -> Void,
        onLogByVoice: (() -> Void)? = nil
    ) {
        self.init(
            viewModel: TrainViewModel(profile: profile, logging: logging),
            onAskCoach: onAskCoach,
            onLogByVoice: onLogByVoice)
    }

    private var snapshot: TrainSnapshot { viewModel.snapshot }

    private var openPlanAction: (() -> Void)? {
        guard let plan = snapshot.activePlan else { return nil }
        return { planSheet = plan }
    }

    private func motion(_ animation: Animation) -> Animation {
        Design.Motion.calm(animation, reduceMotion: reduceMotion)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                            .padding(.bottom, Design.Space.xl)
                            .transition(.shoji(.top, reduceMotion: reduceMotion))
                    }
                    TrainWeekHeader(
                        planName: snapshot.activePlan?.plan.name,
                        week: snapshot.week,
                        onOpenPlan: openPlanAction)
                        .padding(.bottom, Design.Space.xxl)
                    if let draft = snapshot.draftPlan {
                        DraftPlanCard(
                            plan: draft,
                            isActivating: viewModel.isActivatingPlan,
                            onRun: { Task { await viewModel.activateDraft() } },
                            onChange: { onAskCoach(Self.changeDraftPrompt) },
                            onDetails: { planSheet = draft })
                            .padding(.bottom, Design.Space.l)
                            .transition(.ink(reduceMotion: reduceMotion))
                    }
                    // One slot: the outgoing hero and the incoming one share
                    // it while they cross, so nothing below jumps twice.
                    ZStack(alignment: .top) { sessionSection }
                    if !snapshot.personalBests.isEmpty {
                        PRBoardCard(bests: snapshot.personalBests, units: viewModel.units)
                            .padding(.top, Design.Space.section)
                            .id("prs")
                    }
                    if !recentGroups.isEmpty {
                        recentSection
                            .padding(.top, Design.Space.section)
                            .id("recent")
                    }
                    #if DEBUG
                    Color.clear.frame(height: 0).id("bottom")
                    #endif
                }
                .padding(.horizontal, TrainStyle.gutter)
                .padding(.top, Design.Space.m)
                .padding(.bottom, Design.Space.xxl)
                .animation(motion(Design.Motion.arrive), value: snapshot.recent.map(\.id))
                .animation(motion(Design.Motion.settle), value: heroKey)
                .animation(motion(Design.Motion.settle), value: viewModel.errorMessage)
                .animation(motion(Design.Motion.settle), value: snapshot.draftPlan?.id)
            }
            .scrollIndicators(.hidden)
            #if DEBUG
            .task(id: viewModel.hasLoaded) {
                guard let anchor = previewScrollAnchor, viewModel.hasLoaded else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                proxy.scrollTo(anchor, anchor: anchor == "bottom" ? .bottom : .top)
            }
            #endif
        }
        .background(AppBackground())
        .navigationTitle("Train")
        .refreshable { await viewModel.refresh() }
        .task {
            if viewModel.hasLoaded {
                await viewModel.refreshIfStale()
            } else {
                await viewModel.load()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.refreshIfStale() }
        }
        .onChange(of: snapshot.loggedToday) { old, new in
            // A record just landed: today's session finished reading with a
            // PR in it — the one moment besides logging worth a haptic.
            guard let old, let new, old.id == new.id, old.isProcessing,
                  !new.isProcessing, !new.prs.isEmpty else { return }
            freshRecords += 1
        }
        .sheet(item: $logContext) { context in
            WorkoutLogSheet(
                session: context.session,
                targets: context.targets,
                initialKind: context.initialKind,
                initialImage: context.initialImage
            ) { draft in
                _ = viewModel.log(draft, sessionName: context.session?.name)
                submittedLogs += 1
            }
        }
        .sheet(item: $planSheet) { plan in
            TrainingPlanSheet(
                plan: plan,
                isActivating: viewModel.isActivatingPlan,
                onRun: plan.status == .draft ? {
                    Task {
                        await viewModel.activateDraft()
                        planSheet = nil
                    }
                } : nil,
                onChange: { onAskCoach(plan.status == .draft ? Self.changeDraftPrompt : Self.changePlanPrompt) })
        }
        .navigationDestination(for: ActivityRoute.self) { route in
            ActivityDetailContainer(viewModel: viewModel, id: route.id)
        }
        .sensoryFeedback(.success, trigger: submittedLogs)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.8), trigger: freshRecords)
    }

    // MARK: Sections

    /// Today's plan session, once logged, takes the hero spot (and leaves the
    /// history list); otherwise the next session does.
    private var heroActivityId: UUID? {
        snapshot.activePlan == nil ? nil : snapshot.loggedToday?.id
    }

    /// Which hero is showing, so a state change (next → reading → read)
    /// settles instead of popping.
    private var heroKey: String {
        if snapshot.activePlan != nil, let logged = snapshot.loggedToday {
            return "logged-\(logged.id)-\(logged.isProcessing)"
        }
        if let next = snapshot.nextSession { return "next-\(next.id)" }
        return snapshot.activePlan == nil ? "empty" : "none"
    }

    private var recentGroups: [ActivityDayGroup] {
        guard let hero = heroActivityId else { return snapshot.recent }
        return snapshot.recent.compactMap { group in
            var group = group
            group.activities.removeAll { $0.id == hero }
            return group.activities.isEmpty ? nil : group
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        if let plan = snapshot.activePlan {
            if let logged = snapshot.loggedToday {
                NavigationLink(value: ActivityRoute(id: logged.id)) {
                    LoggedSessionCard(
                        activity: logged,
                        sessionName: snapshot.loggedTodaySession?.name,
                        units: viewModel.units)
                }
                .buttonStyle(TrainPanelButtonStyle())
                .disabled(logged.isLocalOnly)
                .transition(.ink(reduceMotion: reduceMotion))
            } else if let next = snapshot.nextSession {
                NextSessionCard(
                    session: next,
                    targets: snapshot.nextTargets,
                    onLogByVoice: onLogByVoice,
                    onType: { logContext = WorkoutLogContext(session: next, targets: snapshot.nextTargets) })
                    .transition(.ink(reduceMotion: reduceMotion))
            } else {
                Text("\(plan.plan.name) has no sessions to run.")
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(Design.Color.textTertiary)
            }
        } else if snapshot.draftPlan == nil, viewModel.hasLoaded {
            EmptyPlanCard { onAskCoach(Self.buildPlanPrompt) }
                .transition(.ink(reduceMotion: reduceMotion))
        }
    }

    /// The history as a diary: the day written once in a narrow left
    /// column, each workout a quiet line. At accessibility sizes the day
    /// moves above its rows instead.
    private var recentSection: some View {
        let diary = !typeSize.isAccessibilitySize
        let today = viewModel.todayLocalDay
        return VStack(alignment: .leading, spacing: 0) {
            TrainStyle.sectionLabel("Recent")
                .padding(.bottom, 6)
            ForEach(recentGroups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    if !diary {
                        Text(group.title)
                            .font(Design.Typeface.text(.footnote))
                            .foregroundStyle(Design.Color.textTertiary)
                            .padding(.top, 10)
                    }
                    // The day is written on the group's first diary line (an
                    // unsent card spans the full width and carries no column).
                    let labelled = group.activities.first { !$0.isLocalOnly }?.id
                    ForEach(group.activities) { activity in
                        activityRow(
                            activity,
                            dayLabel: diary && activity.id == labelled
                                ? ActivityLedgerRow.dayLabel(
                                    localDay: group.localDay, today: today, timezone: viewModel.timezone)
                                : nil,
                            diary: diary)
                            .transition(.ink(reduceMotion: reduceMotion))
                    }
                }
                .padding(.bottom, 6)
            }
            if viewModel.canShowMoreRecent {
                Button {
                    withAnimation(motion(Design.Motion.settle)) { viewModel.showMoreRecent() }
                } label: {
                    HStack(spacing: 5) {
                        Text("Earlier")
                        Image(systemName: "chevron.down")
                            .font(Design.Typeface.text(.caption2, weight: .semibold))
                    }
                    .font(Design.Typeface.text(.footnote, weight: .medium))
                    .foregroundStyle(Design.Color.textTertiary)
                    .padding(.vertical, 10)
                    .padding(.leading, diary ? dayColumnWidth + 14 : 0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: Activity, dayLabel: String?, diary: Bool) -> some View {
        if activity.isLocalOnly {
            // Unsent: the card keeps Retry / Discard where they can't be missed.
            ActivityCard(
                activity: activity,
                units: viewModel.units,
                onRetry: { viewModel.retry(activity) },
                onDiscard: { Task { await viewModel.delete(activity) } })
                .padding(.vertical, 6)
        } else {
            NavigationLink(value: ActivityRoute(id: activity.id)) {
                ActivityLedgerRow(
                    activity: activity,
                    units: viewModel.units,
                    dayLabel: dayLabel,
                    dayColumnWidth: diary ? dayColumnWidth : nil)
            }
            .buttonStyle(TrainRowButtonStyle())
            .contextMenu {
                if !activity.isProcessing {
                    Button(role: .destructive) {
                        Task { await viewModel.delete(activity) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Design.Color.warning)
            Text(message)
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.textSecondary)
            Spacer(minLength: 0)
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Design.Typeface.text(.caption, weight: .bold))
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .cardSurface(radius: Design.Radius.control)
    }
}

/// A list row press: the row dims a touch, nothing moves.
struct TrainRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Design.Motion.snap, value: configuration.isPressed)
    }
}

/// A panel press: it gives a little under the thumb, like a wooden key.
struct TrainPanelButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(Design.Motion.snap, value: configuration.isPressed)
    }
}

/// Live detail for a row owned by `TrainViewModel` (follows processing →
/// complete while open).
struct ActivityDetailContainer: View {
    @ObservedObject var viewModel: TrainViewModel
    let id: UUID
    @State private var lastKnown: Activity?

    var body: some View {
        Group {
            if let activity = viewModel.activity(id: id) ?? lastKnown {
                ActivityDetailView(
                    activity: activity,
                    units: viewModel.units,
                    fallbackPRs: viewModel.fallbackPRs(for: activity),
                    loadImageURL: { [viewModel] _ in await viewModel.imageURL(for: activity) },
                    onRetry: activity.isNotSent ? { viewModel.retry(activity) } : nil,
                    onDelete: { await viewModel.delete(activity) })
                .onAppear { lastKnown = activity }
            } else {
                Text("This workout is gone.")
                    .font(Design.Typeface.text(.subheadline))
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppBackground())
            }
        }
    }
}
