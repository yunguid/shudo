import PhotosUI
import SwiftUI
import UIKit

/// The signed-in app: three tabs (Today · Body · Train) above one command
/// band — Shudo's key carved into the bottom-left corner, the tab bar beside
/// it (the system tab bar is hidden). The shell owns the long-lived state the
/// tabs share — the day's meals, the coach thread, the workout logger — and
/// every capture flow, so talking to Shudo, the meal composer, the camera and
/// check-ins work from any tab.
struct AppShell: View {
    let profile: Profile
    private let dependencies: ShellDependencies

    @StateObject private var today: TodayViewModel
    @StateObject private var coach: CoachViewModel
    @StateObject private var logging: ActivityLoggingController
    @StateObject private var dayContext: TodayDayContext
    /// Transcribers live outside observation: their ~16 Hz meters must
    /// re-render only the views that show them, never the whole shell.
    @StateObject private var coachVoice = UnobservedHolder(VoiceTranscriber(profile: .coach))
    @StateObject private var composerVoice = UnobservedHolder(VoiceTranscriber(profile: .meal))
    @ObservedObject private var router = AppRouter.shared
    /// The one voice/text entry point other screens call
    /// (`startRecording(context:)` / `focusText(context:)`).
    @ObservedObject private var capture = CaptureController.shared

    @State private var tab: AppTab
    @State private var headerExpanded: Bool
    @State private var draft = CaptureDraft()
    @State private var isTyping = false
    @State private var composerHeight: CGFloat = 0
    /// Held, not observed: the bar and the overlay watch the fan, so opening
    /// it mid-press doesn't rebuild the shell (which cancels the press).
    @StateObject private var fanHolder = UnobservedHolder(CaptureFan())
    @State private var sheet: ShellSheet?
    @State private var cover: ShellCover?
    @State private var composerSeed = ComposerSeed()
    @State private var isPickingMealPhoto = false
    @State private var mealPhotoItem: PhotosPickerItem?
    @State private var mealTracker = MealCompletionTracker()
    @State private var bodyRefreshToken = UUID()
    @State private var didLaunch = false
    @State private var bandMetrics = CommandBandMetrics.fallback
    /// Pushed screens with their own bottom bar (the meal page) step the
    /// band aside while they're up.
    @State private var bandSuppressions = 0
    @State private var isKeyboardUp = false
    /// The tab fading in after a tap on the tab bar.
    @State private var fadingTab: AppTab?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(profile: Profile, dependencies: ShellDependencies? = nil) {
        self.profile = profile
        let dependencies = dependencies ?? .live(profile: profile)
        self.dependencies = dependencies
        _today = StateObject(wrappedValue: dependencies.makeToday())
        _coach = StateObject(wrappedValue: dependencies.makeCoach())
        _logging = StateObject(wrappedValue: ActivityLoggingController(service: dependencies.trainService))
        let timezone = profile.timezone
        _dayContext = StateObject(wrappedValue: TodayDayContext(
            localDay: LocalDayMath.today(in: timezone, now: dependencies.now()),
            train: dependencies.trainService,
            body: dependencies.bodyService,
            timezone: { ProfileCache.load(userId: profile.userId)?.timezone ?? timezone }
        ))
        _tab = State(initialValue: dependencies.initialTab)
        _headerExpanded = State(initialValue: dependencies.initialHeaderExpanded)
    }

    private var currentProfile: Profile { today.profile ?? profile }
    private var todayLocalDay: String { LocalDayMath.today(in: currentProfile.timezone, now: dependencies.now()) }

    var body: some View {
        presentations(chrome)
    }

    private var chrome: some View {
        ZStack(alignment: .bottom) {
            // The room behind the tabs: a tab hand-off passes through walnut,
            // never black.
            Design.Color.canvas.ignoresSafeArea()
            tabs
            // The command band replaces the system tab bar and its
            // accessory: the well owns the bottom-left corner, the tabs sit
            // beside it. A sibling, not an overlay, so it reaches the
            // screen's bottom edge.
            commandBand
        }
        .overlay(alignment: .bottom) { typingOverlay }
        .overlay { CaptureFanOverlay(fan: fanHolder.value, metrics: bandMetrics) }
        .environment(\.captureComposerInset, isTyping ? composerHeight : 0)
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: isTyping)
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: bandHidden)
        .onAppear(perform: measureBand)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardUp = false
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "bubble.left.and.text.bubble.right.fill", value: AppTab.today) {
                banded(todayScreen, tab: .today)
            }

            Tab("Body", systemImage: "figure.arms.open", value: AppTab.body) {
                banded(
                    dependencies.makeBodyScreen(currentProfile) { saved in checkInSaved(saved) }
                        .id(bodyRefreshToken),
                    tab: .body
                )
            }

            Tab("Train", systemImage: "dumbbell.fill", value: AppTab.train) {
                banded(
                    NavigationStack {
                        TrainScreen(
                            viewModel: dependencies.makeTrainViewModel(currentProfile, logging),
                            onAskCoach: { sendToCoach($0, mode: .typed, engine: nil) },
                            // One mic: "Log session" records in the bottom-left well.
                            onLogByVoice: { CaptureController.shared.startRecording(context: .train) }
                        )
                    },
                    tab: .train
                )
            }
        }
        .tint(Design.Color.ember)
    }
}

extension AppShell {
    /// The shell's sheets, covers and event wiring (split out of `body` to
    /// keep the type checker fast).
    fileprivate func presentations(_ content: some View) -> some View {
        content
        .sheet(isPresented: $today.isPresentingComposer, onDismiss: composerDismissed) { composer }
        .sheet(item: $sheet) { sheet in sheetContent(sheet) }
        .fullScreenCover(item: $cover) { cover in coverContent(cover) }
        .photosPicker(isPresented: $isPickingMealPhoto, selection: $mealPhotoItem, matching: .images)
        .onChange(of: mealPhotoItem) { _, item in loadPickedMealPhoto(item) }
        .onAppear(perform: launch)
        .onChange(of: today.entries) { _, entries in
            for id in mealTracker.observe(entries) {
                dependencies.recordEvent(.mealCompleted(entryId: id))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            updatePresence()
            guard phase == .active else { return }
            Task { await coach.onForeground() }
            guard dependencies.loadsRemotely else { return }
            Task { await today.reconcileAfterActivation() }
            Task { await dayContext.refreshAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            guard dependencies.loadsRemotely else { return }
            Task { await today.reconcileAfterActivation() }
        }
        .onChange(of: tab) { _, newTab in
            capture.setTab(newTab)
            updatePresence()
        }
        .onChange(of: capture.request) { _, request in handle(captureControllerRequest: request) }
        .onChange(of: sheet?.id) { _, _ in updatePresence() }
        .onChange(of: cover?.id) { _, _ in updatePresence() }
        .onChange(of: today.isPresentingComposer) { _, _ in updatePresence() }
        .onChange(of: router.coachRequest) { _, request in handle(coachRequest: request) }
        .onChange(of: router.captureRequest) { _, request in handle(captureRequest: request) }
        .onChange(of: profile) { _, updated in
            guard dependencies.loadsRemotely else { return }
            Task { await today.loadFor(profile: updated) }
        }
        .onDisappear { CoachPresence.shared.isThreadVisible = false }
    }

    // MARK: Command band

    /// Typing, a keyboard, or a meal page with its own fix bar: the band
    /// steps down out of the way.
    private var bandHidden: Bool { isTyping || isKeyboardUp || bandSuppressions > 0 }

    /// The one source of truth for the reserved bottom band: every tab's
    /// safe area ends above it.
    private var bandInset: CGFloat { bandHidden ? 0 : bandMetrics.safeAreaInset }

    private func banded(_ content: some View, tab: AppTab) -> some View {
        content
            .opacity(fadingTab == tab ? 0 : 1)
            .toolbarVisibility(.hidden, for: .tabBar)
            // SwiftUI safe-area modifiers stop at the tab's UIKit
            // navigation stacks; the tab controller's own inset reaches
            // every screen and every pushed page.
            .background(TabSafeAreaInset(bottom: bandInset))
            .environment(\.shellBandInset, bandInset)
            .environment(\.setShellBandSuppressed) { suppressed in
                bandSuppressions = max(0, bandSuppressions + (suppressed ? 1 : -1))
            }
    }

    @ViewBuilder
    private var commandBand: some View {
        if !bandHidden {
            CaptureBar(
                voice: coachVoice.value,
                draft: $draft,
                context: capture.context,
                actions: captureActions,
                fan: fanHolder.value,
                tab: Binding(get: { tab }, set: { switchTab(to: $0) }),
                todayBadge: tab == .today ? 0 : coach.unreadCount,
                metrics: bandMetrics
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// A tap on the tab bar (or a card that opens a tab) is a hand-off,
    /// never a blend. UIKit's own tab crossfade (both screens at half
    /// opacity) is suppressed for the swap, so the outgoing tab is simply
    /// gone; the incoming one fades up from the canvas over ~0.18 s, no
    /// movement. Reduce Motion: an instant swap. Jumps that happen while a
    /// sheet is closing (a send, a logged meal) set `tab` directly, so the
    /// sheet's own dismissal animation is never switched off.
    private func switchTab(to new: AppTab) {
        guard new != tab else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        UIView.setAnimationsEnabled(false)
        withTransaction(quiet) {
            fadingTab = reduceMotion ? nil : new
            tab = new
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            UIView.setAnimationsEnabled(true)
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.18)) { fadingTab = nil }
        }
    }

    private func measureBand() {
        let window = (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?
            .windows.first { $0.isKeyWindow }
        bandMetrics = CommandBandMetrics(
            displayCornerRadius: DisplayCorner.radius,
            bottomSafeArea: window?.safeAreaInsets.bottom ?? CommandBandMetrics.fallback.bottomSafeArea
        )
    }

    // MARK: Tabs

    private var todayScreen: some View {
        TodayScreen(
            profile: currentProfile,
            today: today,
            coach: coach,
            context: dayContext,
            logging: logging,
            environment: TodayScreenEnvironment(
                loadsRemotely: dependencies.loadsRemotely,
                previewEntryDetail: dependencies.previewEntryDetail,
                coachMediaURL: dependencies.coachMediaURL,
                trainService: dependencies.trainService,
                bodyService: dependencies.bodyService,
                makeInsights: insightsScreen,
                now: dependencies.now
            ),
            actions: TodayScreenActions(
                openSettings: { sheet = .account(scrollToCoach: false) },
                openBio: { sheet = .bio },
                switchTab: { switchTab(to: $0) },
                sendToCoach: { sendToCoach($0, mode: .typed, engine: nil) },
                refreshProfile: refreshProfile
            ),
            headerExpanded: $headerExpanded,
            isActiveTab: tab == .today
        )
    }

    private func insightsScreen(_ profile: Profile) -> AnyView {
        #if DEBUG
        if !dependencies.loadsRemotely {
            return AnyView(WeeklyInsightsScreen(
                previewProfile: profile,
                summaries: [],
                dailyTotals: dayContext.dayTotals,
                targetHistory: dayContext.targetHistory
            ))
        }
        #endif
        return AnyView(WeeklyInsightsScreen(profile: profile))
    }

    // MARK: Capture

    private var captureActions: CaptureBarActions {
        CaptureBarActions(
            send: { text, mode, engine in
                sendToCoach(text, mode: mode, engine: engine, hint: capture.context.contextHint)
            },
            logMeal: { openComposer(autoStartRecording: false) },
            logWorkout: { sheet = .workoutLog(WorkoutLogContext()) },
            mealPhoto: {
                if CameraAvailability.hasCamera {
                    cover = .camera(.meal)
                } else {
                    isPickingMealPhoto = true
                }
            },
            scanBarcode: { openComposer(autoStartRecording: false, opensScanner: true) },
            workoutPhoto: {
                if CameraAvailability.hasCamera {
                    cover = .camera(.workout)
                } else {
                    sheet = .workoutLog(WorkoutLogContext(initialKind: .strength))
                }
            },
            checkIn: { cover = .checkIn },
            beginTyping: {
                warmLocation()
                isTyping = true
            },
            willCompose: warmLocation,
            captureEnded: { capture.captureEnded() }
        )
    }

    /// The keyboard-docked composer (the band itself steps under the
    /// keyboard). On Today the thread stays bright and makes room for it
    /// (`captureComposerInset`) — you're replying to what's there. Elsewhere
    /// a light scrim; tap it to tuck the draft back into the bar.
    @ViewBuilder
    private var typingOverlay: some View {
        if isTyping {
            ZStack(alignment: .bottom) {
                if tab != .today {
                    Design.Color.canvas.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { isTyping = false }
                        .accessibilityHidden(true)
                }
                CaptureComposer(
                    draft: $draft,
                    placeholder: capture.context.placeholder,
                    onSend: sendDraft,
                    onDictate: {
                        isTyping = false
                        let voice = coachVoice.value
                        voice.transcriptionPurposeOverride = capture.context.transcriptionPurpose
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            _ = await voice.start()
                        }
                    },
                    onClose: { isTyping = false }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                .transition(.shoji(.bottom, reduceMotion: reduceMotion))
            }
            .transition(.opacity)
        }
    }

    private func sendDraft() {
        guard let submission = draft.submission else { return }
        sendToCoach(
            submission.text,
            mode: submission.mode,
            engine: submission.speechEngine,
            hint: capture.context.contextHint
        )
        draft.clear()
        isTyping = false
        capture.captureEnded()
    }

    private func sendToCoach(_ text: String, mode: CoachInputMode, engine: String?, hint: CoachContextHint? = nil) {
        guard coach.send(text: text, mode: mode, speechEngine: engine, contextHint: hint) != nil else { return }
        if hint != .bio { tab = .today }
    }

    /// "Nearby store recs": refresh the on-device store scan while Luke is
    /// composing so the send carries a fresh `LocationContext`.
    private func warmLocation() {
        guard dependencies.loadsRemotely else { return }
        Task { _ = await NearbyStoreScout.shared.contextIfEnabled(maxAge: 10 * 60, refreshIfStale: true) }
    }

    /// The classic composer. A voice start begins the microphone warm-up at
    /// the tap so session activation overlaps the sheet animation.
    private func openComposer(autoStartRecording: Bool, images: [UIImage] = [], opensScanner: Bool = false) {
        Perf.mark(autoStartRecording ? "mic.tap" : "compose.tap")
        composerSeed = ComposerSeed(
            autoStartRecording: autoStartRecording,
            images: images.isEmpty ? dependencies.composerSeedImages : images,
            opensScanner: opensScanner
        )
        if coachVoice.value.isBusy { coachVoice.value.cancel() }
        if autoStartRecording, sheet == nil, cover == nil {
            let voice = composerVoice.value
            Task { await voice.start() }
        }
        sheet = nil
        today.isPresentingComposer = true
    }

    private var composer: some View {
        let capturedDay = today.currentDay
        return EntryComposerView(
            selectedDay: capturedDay,
            timezone: currentProfile.timezone,
            autoStartRecording: composerSeed.autoStartRecording,
            voice: composerVoice.value,
            initialImages: composerSeed.images,
            opensBarcodeScannerOnAppear: composerSeed.opensScanner
        ) { draft in
            today.acceptEntrySubmission(
                text: draft.text,
                speechEngine: draft.speechEngine,
                imageJPEG: draft.imageJPEG,
                for: capturedDay,
                clientRequestId: draft.clientRequestId
            )
            dependencies.recordEvent(.mealLogged)
            tab = .today
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Design.Radius.sheet)
    }

    private func composerDismissed() {
        let voice = composerVoice.value
        CaptureDiagnostics.record(.composerDismissed, state: voice.controlState)
        voice.cancel()
    }

    private func submitWorkout(_ draft: WorkoutLogDraft, sessionName: String?) {
        logging.submit(draft, localDay: todayLocalDay, timezone: currentProfile.timezone, sessionName: sessionName)
        tab = .today
    }

    // MARK: Sheets and covers

    @ViewBuilder
    private func sheetContent(_ sheet: ShellSheet) -> some View {
        switch sheet {
        case .account(let scrollToCoach):
            NavigationStack {
                dependencies.makeAccountView(currentProfile, accountHooks(scrollToCoach: scrollToCoach))
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        case .bio:
            NavigationStack {
                BioView(
                    coachService: dependencies.coachService,
                    loadRevisions: dependencies.bioRevisions,
                    onSend: { text, engine in
                        sendToCoach(text, mode: engine == nil ? .typed : .dictated, engine: engine, hint: .bio)
                    },
                    // One mic: closes settings, jumps to Today, records in the bar.
                    onTalkToUpdate: { CaptureController.shared.startRecording(context: .bio) }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { self.sheet = nil }
                            .tint(Design.Color.textPrimary)
                    }
                }
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        case .workoutLog(let context):
            WorkoutLogSheet(
                session: context.session,
                targets: context.targets,
                initialKind: context.initialKind,
                initialImage: context.initialImage
            ) { draft in
                submitWorkout(draft, sessionName: context.session?.name)
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        }
    }

    @ViewBuilder
    private func coverContent(_ cover: ShellCover) -> some View {
        switch cover {
        case .camera(let purpose):
            CameraPicker { image in
                Task { @MainActor in
                    // Let the camera dismiss before the next presentation.
                    try? await Task.sleep(for: .milliseconds(450))
                    switch purpose {
                    case .meal: openComposer(autoStartRecording: false, images: [image])
                    case .workout: sheet = .workoutLog(WorkoutLogContext(initialKind: .strength, initialImage: image))
                    }
                }
            }
            .ignoresSafeArea()
        case .checkIn:
            BodyCheckInFlow(
                localDay: todayLocalDay,
                units: currentProfile.units,
                existing: dayContext.checkIns.first { $0.localDay == todayLocalDay },
                start: .camera,
                service: dependencies.bodyService
            ) { saved in
                checkInSaved(saved)
                bodyRefreshToken = UUID()
            }
        }
    }

    private func loadPickedMealPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            mealPhotoItem = nil
            guard let data, let image = UIImage(data: data) else { return }
            openComposer(autoStartRecording: false, images: [image])
        }
    }

    private func accountHooks(scrollToCoach: Bool) -> AccountView.ShellHooks {
        AccountView.ShellHooks(
            coachService: dependencies.coachService,
            loadsRemotely: dependencies.loadsRemotely,
            scrollToCoach: scrollToCoach,
            onProfileUpdated: { updated in today.applyProfile(updated) },
            onSettingsChanged: { settings in
                guard dependencies.loadsRemotely else { return }
                Task { await CoachSync.shared.apply(settings: settings) }
            },
            openBio: { sheet = .bio },
            bioDestination: {
                AnyView(BioView(
                    coachService: dependencies.coachService,
                    loadRevisions: dependencies.bioRevisions,
                    onSend: { text, engine in
                        sendToCoach(text, mode: engine == nil ? .typed : .dictated, engine: engine, hint: .bio)
                    },
                    // One mic: closes settings, jumps to Today, records in the bar.
                    onTalkToUpdate: { CaptureController.shared.startRecording(context: .bio) }
                ))
            },
            onSignOut: {
                guard dependencies.loadsRemotely else { return }
                Task { await CoachSync.shared.reset() }
                NearbyStoreScout.shared.clear()
                CoachPresence.shared.isThreadVisible = false
            }
        )
    }

    // MARK: Events

    private func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        #if DEBUG
        // `-shudoPreviewTabSwitch body|train|today`: tap that tab after 2 s
        // (frame review of the tab hand-off).
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-shudoPreviewTabSwitch"), arguments.indices.contains(flag + 1),
           let target = AppTab(rawValue: arguments[flag + 1]) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                switchTab(to: target)
            }
        }
        #endif
        mealTracker = MealCompletionTracker()
        _ = mealTracker.observe(today.entries)
        logging.onActivityAccepted = { _ in dependencies.recordEvent(.activityLogged) }
        logging.onActivitySettled = { activity in
            if activity.status == .complete {
                dependencies.recordEvent(.activityCompleted(activityId: activity.id))
            }
            Task { await dayContext.load(localDay: dayContext.localDay) }
        }
        capture.setTab(tab)
        updatePresence()
        handle(captureControllerRequest: capture.request)
        handle(coachRequest: router.coachRequest)
        handle(captureRequest: router.captureRequest)
        Task {
            await coach.refresh()
            dependencies.onLaunch?(coach)
        }
        Task { await dayContext.refreshAll() }
    }

    private func checkInSaved(_ saved: WeightCheckIn) {
        dayContext.upsert(saved)
        dependencies.recordEvent(.checkInLogged)
    }

    private func refreshProfile() {
        guard dependencies.loadsRemotely else { return }
        Task {
            guard let fresh = try? await SupabaseService().fetchProfile(userId: currentProfile.userId) else { return }
            ProfileCache.save(fresh)
            today.applyProfile(fresh)
        }
    }

    private func updatePresence() {
        CoachPresence.shared.isThreadVisible = CoachPresencePolicy.isThreadVisible(
            tab: tab,
            sceneActive: scenePhase == .active,
            isPresentingOverThread: sheet != nil || cover != nil || today.isPresentingComposer
        )
    }

    private func handle(coachRequest request: AppRouter.CoachRequest?) {
        guard let request else { return }
        router.consume(request)
        switch request.destination {
        case .settings:
            today.isPresentingComposer = false
            cover = nil
            sheet = .account(scrollToCoach: true)
        case .thread(let messageId, let localDay):
            sheet = nil
            cover = nil
            today.isPresentingComposer = false
            tab = .today
            Task { await coach.focus(messageId: messageId, day: localDay) }
        }
    }

    /// `shudo://capture`: voice goes through the one entry point — the
    /// bar records on Today (the coach logs a described meal).
    private func handle(captureRequest request: AppRouter.CaptureRequest?) {
        guard let request else { return }
        router.consume(request)
        if request.autoStartRecording {
            capture.startRecording(context: .today)
        } else {
            tab = .today
            openComposer(autoStartRecording: false)
        }
    }

    /// `CaptureController.startRecording(context:)` / `focusText(context:)`
    /// from anywhere: close whatever covers the bar (Settings for `.bio`),
    /// go to the context's tab, then record or open the keyboard composer.
    private func handle(captureControllerRequest request: CaptureController.Request?) {
        guard let request else { return }
        capture.consume(request)
        let wasCovered = sheet != nil || cover != nil || today.isPresentingComposer
        sheet = nil
        cover = nil
        today.isPresentingComposer = false
        if tab != request.context.tab { tab = request.context.tab }
        let voice = coachVoice.value
        Task { @MainActor in
            // Let a dismissing sheet get out of the way first.
            if wasCovered { try? await Task.sleep(for: .milliseconds(450)) }
            switch request.action {
            case .record:
                guard !voice.isBusy, !voice.canRetryTranscription else { return }
                isTyping = false
                warmLocation()
                voice.transcriptionPurposeOverride = request.context.transcriptionPurpose
                _ = await voice.start()
            case .type:
                warmLocation()
                isTyping = true
            }
        }
    }
}

// MARK: - Presentation state

struct ComposerSeed {
    var autoStartRecording = false
    var images: [UIImage] = []
    var opensScanner = false
}

enum ShellSheet: Identifiable {
    case account(scrollToCoach: Bool)
    case bio
    case workoutLog(WorkoutLogContext)

    var id: String {
        switch self {
        case .account: return "account"
        case .bio: return "bio"
        case .workoutLog(let context): return "workout-\(context.id.uuidString)"
        }
    }
}

enum ShellCover: Identifiable {
    enum CameraPurpose: String { case meal, workout }
    case camera(CameraPurpose)
    case checkIn

    var id: String {
        switch self {
        case .camera(let purpose): return "camera-\(purpose.rawValue)"
        case .checkIn: return "check-in"
        }
    }
}

enum CameraAvailability {
    @MainActor static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
}
