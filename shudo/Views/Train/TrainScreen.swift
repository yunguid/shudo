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

/// The Train tab: this week's ring, the plan's next session with targets to
/// beat, PRs and history. Host it inside a `NavigationStack` (activity
/// detail pushes onto it):
///
///     NavigationStack {
///         TrainScreen(profile: profile, onAskCoach: { coach.compose($0) })
///     }
///
/// `onAskCoach` receives a complete sentence for the coach ("Build me a
/// training plan…") — send it, or prefill the capture bar with it.
struct TrainScreen: View {
    @StateObject private var viewModel: TrainViewModel
    var onAskCoach: (String) -> Void
    var onDictate: WorkoutDictationHook?

    @State private var logContext: WorkoutLogContext?
    @State private var planSheet: TrainingPlan?

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
        onDictate: WorkoutDictationHook? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.onAskCoach = onAskCoach
        self.onDictate = onDictate
    }

    /// Convenience for the app shell. Pass a shared `logging` controller so
    /// workouts logged from Today show up here (and vice versa).
    init(
        profile: Profile,
        logging: ActivityLoggingController? = nil,
        onAskCoach: @escaping (String) -> Void,
        onDictate: WorkoutDictationHook? = nil
    ) {
        self.init(
            viewModel: TrainViewModel(profile: profile, logging: logging),
            onAskCoach: onAskCoach,
            onDictate: onDictate)
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
                    recentSection
                        .id("recent")
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
                }
                .accessibilityLabel("Log a workout")
            }
        }
        .refreshable { await viewModel.refresh() }
        .task {
            if !viewModel.hasLoaded { await viewModel.load() }
        }
        .sheet(item: $logContext) { context in
            WorkoutLogSheet(
                session: context.session,
                targets: context.targets,
                initialKind: context.initialKind,
                initialImage: context.initialImage,
                onDictate: onDictate
            ) { draft in
                _ = viewModel.log(draft, sessionName: context.session?.name)
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
        .sensoryFeedback(.success, trigger: snapshot.week.completed) { old, new in new > old }
    }

    // MARK: Sections

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
            }
            if let next = snapshot.nextSession {
                NextSessionCard(
                    session: next,
                    targets: snapshot.nextTargets,
                    eyebrow: snapshot.loggedToday == nil ? "Next up" : "Next session",
                    isSecondary: snapshot.loggedToday != nil
                ) {
                    logContext = WorkoutLogContext(session: next, targets: snapshot.nextTargets)
                }
            } else {
                Text("\(plan.plan.name) has no sessions to run.")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
            Button {
                onAskCoach(Self.changePlanPrompt)
            } label: {
                Label("Change my plan", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.Color.textSecondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
        } else if snapshot.draftPlan == nil, viewModel.hasLoaded {
            EmptyPlanCard { onAskCoach(Self.buildPlanPrompt) }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").eyebrowStyle()
                Spacer()
                Button {
                    logContext = WorkoutLogContext()
                } label: {
                    Label("Log", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.ember)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
            if snapshot.recent.isEmpty {
                Text(viewModel.hasLoaded
                    ? "Nothing logged yet. After your next session, tap Log and say it like you’d text a friend — or drop in your Watch screenshot."
                    : "Loading your training…")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textTertiary)
                    .padding(.vertical, 8)
            }
            ForEach(snapshot.recent) { group in
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
                    .foregroundStyle(Design.Color.ember)
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
