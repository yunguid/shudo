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

/// The Train tab: this week's strip, the plan's next session with numbers
/// to beat (or today's, once it's logged), PRs and history. Host it inside a
/// `NavigationStack` (activity detail pushes onto it):
///
///     NavigationStack {
///         TrainScreen(profile: profile, onAskCoach: { coach.compose($0) })
///     }
///
/// `onAskCoach` receives a complete sentence for the coach ("Build me a
/// training plan…") — send it, or prefill the capture bar with it.
/// `onLogByVoice` is "Log session": the shell binds it to the capture bar's
/// mic in the Train context. Unbound, it opens the typed logger instead.
struct TrainScreen: View {
    @StateObject private var viewModel: TrainViewModel
    var onAskCoach: (String) -> Void
    var onLogByVoice: (() -> Void)?

    @State private var logContext: WorkoutLogContext?
    @State private var planSheet: TrainingPlan?
    @State private var submittedLogs = 0
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    /// PolishPreview only: scroll to an anchor ("prs", "recent") after load.
    var previewScrollAnchor: String?
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                    TrainWeekHeader(
                        planName: snapshot.activePlan?.plan.name,
                        week: snapshot.week,
                        onOpenPlan: openPlanAction)
                    if let draft = snapshot.draftPlan {
                        DraftPlanCard(
                            plan: draft,
                            isActivating: viewModel.isActivatingPlan,
                            onRun: { Task { await viewModel.activateDraft() } },
                            onChange: { onAskCoach(Self.changeDraftPrompt) },
                            onDetails: { planSheet = draft })
                    }
                    sessionSection
                    if !snapshot.personalBests.isEmpty {
                        PRBoardCard(bests: snapshot.personalBests, units: viewModel.units)
                            .id("prs")
                    }
                    if !recentGroups.isEmpty {
                        recentSection
                            .id("recent")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .animation(Design.Motion.arrive, value: snapshot.recent.map(\.id))
            }
            .scrollIndicators(.hidden)
            #if DEBUG
            .task(id: viewModel.hasLoaded) {
                guard let anchor = previewScrollAnchor, viewModel.hasLoaded else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                proxy.scrollTo(anchor, anchor: .top)
            }
            #endif
        }
        .background(Design.Color.canvas.ignoresSafeArea())
        .navigationTitle("Train")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    logContext = WorkoutLogContext()
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                }
                .accessibilityLabel("Log a workout")
            }
        }
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
    }

    // MARK: Sections

    /// Today's plan session, once logged, takes the hero spot (and leaves the
    /// history list); otherwise the next session does.
    private var heroActivityId: UUID? {
        snapshot.activePlan == nil ? nil : snapshot.loggedToday?.id
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
                .buttonStyle(.plain)
                .disabled(logged.isLocalOnly)
            } else if let next = snapshot.nextSession {
                NextSessionCard(
                    session: next,
                    targets: snapshot.nextTargets,
                    onLog: {
                        if let onLogByVoice {
                            onLogByVoice()
                        } else {
                            logContext = WorkoutLogContext(session: next, targets: snapshot.nextTargets)
                        }
                    },
                    onType: { logContext = WorkoutLogContext(session: next, targets: snapshot.nextTargets) })
            } else {
                Text("\(plan.plan.name) has no sessions to run.")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        } else if snapshot.draftPlan == nil, viewModel.hasLoaded {
            EmptyPlanCard { onAskCoach(Self.buildPlanPrompt) }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent").eyebrowStyle()
                .padding(.top, 10)
            ForEach(recentGroups) { group in
                Text(group.title)
                    .font(Design.Typeface.meta)
                    .foregroundStyle(Design.Color.textTertiary)
                    .padding(.top, 4)
                ForEach(group.activities) { activity in
                    activityRow(activity)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            if viewModel.canShowMoreRecent {
                Button("Show more") { viewModel.showMoreRecent() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ activity: Activity) -> some View {
        if activity.isLocalOnly {
            ActivityCard(
                activity: activity,
                units: viewModel.units,
                onRetry: { viewModel.retry(activity) },
                onDiscard: { Task { await viewModel.delete(activity) } })
        } else {
            NavigationLink(value: ActivityRoute(id: activity.id)) {
                ActivityCard(activity: activity, units: viewModel.units)
            }
            .buttonStyle(.plain)
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
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
            Spacer(minLength: 0)
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .cardSurface(radius: Design.Radius.control)
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
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Design.Color.canvas.ignoresSafeArea())
            }
        }
    }
}
