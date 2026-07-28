import Foundation

/// A locally accepted meal correction. The composer hands this to
/// `TodayViewModel` and dismisses immediately; the payload is kept until the
/// server accepts the update so a failure can be retried without retyping or
/// re-recording anything.
struct EntryCorrectionSubmission: Equatable {
    let text: String?
    let audioData: Data?
    let clientRequestId: UUID
}

enum EntryCorrectionPresentation {
    static let processingMessage = "Updating nutrition estimate"
    static let rollbackMessage = "The meal update failed. Your previous estimate was restored."
    static let failureHeadline = "Update failed — previous estimate kept"

    static func processingEntry(from entry: Entry, at date: Date = Date()) -> Entry {
        var updated = entry
        updated.status = .analyzing
        updated.statusMessage = processingMessage
        updated.errorMessage = nil
        updated.analysisPreview = nil
        updated.statusUpdatedAt = date
        return updated
    }

    /// Whether a day reload already contains the corrected values, or the
    /// locally known post-correction row should overlay the fetched one. A
    /// reload that raced the correction can return rows read before the
    /// server finalized the update; `updated_at` disambiguates.
    static func serverRowReflectsCorrection(fetched: Entry, corrected: Entry) -> Bool {
        guard let fetchedAt = fetched.statusUpdatedAt,
              let correctedAt = corrected.statusUpdatedAt else { return true }
        return fetchedAt >= correctedAt
    }
}

@MainActor
final class TodayViewModel: ObservableObject {
    @Published var profile: Profile?
    @Published private(set) var todayTotals: DayTotals = .empty
    @Published private(set) var entries: [Entry] = [] {
        didSet {
            // Write-through snapshot of the visible day, so returning to it
            // renders instantly instead of flashing a loading skeleton. The
            // load-failure path suppresses this: a fallback (possibly empty)
            // list must not overwrite a good snapshot.
            guard !suppressDayCacheWrite, !currentLocalDay.isEmpty else { return }
            dayCache[currentLocalDay] = entries
        }
    }
    @Published private(set) var currentDay: Date = Date()
    @Published var isPresentingComposer = false
    @Published var errorMessage: String?
    @Published private(set) var isPinnedToToday = true
    @Published private(set) var isLoadingDay = false
    @Published private(set) var resumingEntryIds: Set<UUID> = []
    @Published private(set) var completionRevealEntryIds: Set<UUID> = []
    @Published private(set) var effectiveTarget: MacroTarget
    /// User-facing failure message per entry whose last correction attempt
    /// didn't go through; the timeline shows a retry banner while this is set.
    @Published private(set) var failedCorrections: [UUID: String] = [:]

    let api: APIService
    let supabase: SupabaseService
    private let reanalysis: any EntryReanalysisServing
    private let fetchEntryById: (UUID) async throws -> Entry?

    private var loadGeneration = UUID()
    /// Per-day entry snapshots for instant day switching; pruned LRU by
    /// visit order. Keys are localDay strings for the profile's timezone.
    private var dayCache: [String: [Entry]] = [:]
    private var dayCacheVisitOrder: [String] = []
    private var currentLocalDay = ""
    private var suppressDayCacheWrite = false
    private static let maximumCachedDays = 16
    /// Meals accepted locally whose create call hasn't succeeded yet, keyed
    /// by placeholder id. The payload outlives the composer so failures are
    /// retryable without recomposing anything.
    private var pendingSubmissions: [UUID: PendingEntrySubmission] = [:]
    private var submissionTasks: [UUID: Task<Void, Never>] = [:]
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private var pollingTokens: [UUID: UUID] = [:]
    private var autoResumeRequestStates: [UUID: AutoResumeRequestState] = [:]
    private var resumeNotices: [UUID: String] = [:]
    private var correctionSnapshots: [UUID: Entry] = [:]
    private var correctionTasks: [UUID: Task<Void, Never>] = [:]
    private var correctionPayloads: [UUID: EntryCorrectionSubmission] = [:]
    private var correctionResults: [UUID: Entry] = [:]
    private var targetHistory: [DailyMacroTargetSnapshot] = []

    static let staleResumeInterval: TimeInterval = 145
    static let autoResumeRetryInterval: TimeInterval = 50
    static let streamingPreviewPollingInterval: UInt64 = 650_000_000
    static let maximumPollingInterval: UInt64 = 3_000_000_000
    private static let maximumProcessingAttempts = 3

    struct AutoResumeRequestState: Equatable {
        let attempt: Int
        let retryAfter: Date?
    }

    private enum ResumeRequestOutcome {
        case accepted
        case conflict
        case failed
    }

    init(
        profile: Profile,
        api: APIService,
        supabase: SupabaseService = SupabaseService(),
        reanalysis: (any EntryReanalysisServing)? = nil,
        fetchEntryById: ((UUID) async throws -> Entry?)? = nil,
        preloadedEntries: [Entry]? = nil,
        preloadedDay: Date = Date()
    ) {
        self.api = api
        self.supabase = supabase
        self.reanalysis = reanalysis ?? api
        self.fetchEntryById = fetchEntryById ?? { id in
            try await supabase.fetchEntry(id: id)
        }
        self.profile = profile
        self.effectiveTarget = profile.dailyMacroTarget
        if let preloadedEntries {
            currentDay = preloadedDay
            currentLocalDay = supabase.localDayString(
                for: preloadedDay,
                timezone: profile.timezone
            )
            entries = preloadedEntries
            todayTotals = Self.totals(for: preloadedEntries)
            isPinnedToToday = true
            isLoadingDay = false
            touchDayCacheVisit(currentLocalDay)
        } else {
            Task { await load(day: Date()) }
        }
    }

    var hasProcessingEntries: Bool { entries.contains { $0.status.isProcessing } }

    func applyProfile(_ updatedProfile: Profile) {
        profile = updatedProfile
        effectiveTarget = updatedProfile.dailyMacroTarget
        targetHistory = []
        ProfileCache.save(updatedProfile)
        Task { await refreshTargetHistory() }
    }

    func loadFor(profile: Profile) async {
        self.profile = profile
        await load(day: currentDay)
    }

    func reconcileAfterActivation(now: Date = Date()) async {
        let timezone = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier
        let targetDay = Self.shouldAdvancePinnedDay(
            currentDay: currentDay,
            now: now,
            timezone: timezone,
            wasPinnedToToday: isPinnedToToday
        ) ? now : currentDay
        await load(day: targetDay)
    }

    func load(day: Date) async {
        Perf.mark("day.load.begin")
        let timezone = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier
        let requestedLocalDay = supabase.localDayString(for: day, timezone: timezone)
        let visibleLocalDay = entries.first?.localDay
            ?? supabase.localDayString(for: currentDay, timezone: timezone)
        let previouslyVisibleEntries = entries
        let previouslyVisibleTotals = todayTotals
        let generation = UUID()
        pollingTasks.values.forEach { $0.cancel() }
        pollingTasks.removeAll()
        pollingTokens.removeAll()
        completionRevealEntryIds.removeAll()
        loadGeneration = generation
        currentDay = day
        currentLocalDay = requestedLocalDay
        isPinnedToToday = isToday(day, timezone: timezone)
        errorMessage = nil

        // Days already on screen or previously visited render instantly and
        // refresh in the background; only unseen days show the skeleton.
        let contentAlreadyVisible: Bool
        if requestedLocalDay == visibleLocalDay, !entries.isEmpty {
            // Reloading the visible day (pull-to-refresh, foreground
            // reconcile): keep the content instead of flashing skeletons.
            contentAlreadyVisible = true
            isLoadingDay = false
        } else if requestedLocalDay != visibleLocalDay,
                  let cached = dayCache[requestedLocalDay] {
            entries = cached
            reapplyCorrectionStateAfterLoad()
            recomputeTotals()
            isLoadingDay = false
            contentAlreadyVisible = true
            Perf.mark("day.load.cached.visible")
        } else {
            contentAlreadyVisible = false
            isLoadingDay = true
        }
        touchDayCacheVisit(requestedLocalDay)

        do {
            // Target history improves progress accuracy, but it must not make the
            // primary meal log unavailable or keep its loading skeleton visible.
            async let targetRequest = try? supabase.fetchDailyMacroTargetHistory()
            let items = try await supabase.fetchEntries(for: day, timezone: timezone)
            guard loadGeneration == generation else { return }
            entries = items
            reapplyCorrectionStateAfterLoad()
            recomputeTotals()
            effectiveTarget = NutritionProgressPolicy.effectiveTarget(
                on: requestedLocalDay,
                history: targetHistory,
                fallback: profile?.dailyMacroTarget ?? .defaultDaily
            )
            isLoadingDay = false
            Perf.mark("day.load.visible")

            for item in items where item.status.isProcessing && correctionTasks[item.id] == nil {
                startPolling(entryId: item.id, localDay: item.localDay ?? localDay(for: day))
            }

            let loadedTargetHistory = await targetRequest
            guard loadGeneration == generation else { return }
            targetHistory = Self.targetHistoryAfterLoad(
                loaded: loadedTargetHistory,
                current: targetHistory
            )
            effectiveTarget = NutritionProgressPolicy.effectiveTarget(
                on: requestedLocalDay,
                history: targetHistory,
                fallback: profile?.dailyMacroTarget ?? .defaultDaily
            )
        } catch {
            guard loadGeneration == generation else { return }
            if !contentAlreadyVisible {
                let fallback = Self.visibleStateAfterLoadFailure(
                    previousEntries: previouslyVisibleEntries,
                    previousTotals: previouslyVisibleTotals,
                    visibleLocalDay: visibleLocalDay,
                    requestedLocalDay: requestedLocalDay
                )
                // A fallback (possibly empty) list is not server truth for
                // the requested day; never let it overwrite a snapshot.
                suppressDayCacheWrite = true
                entries = fallback.entries
                suppressDayCacheWrite = false
                todayTotals = fallback.totals
            }
            effectiveTarget = NutritionProgressPolicy.effectiveTarget(
                on: requestedLocalDay,
                history: targetHistory,
                fallback: profile?.dailyMacroTarget ?? .defaultDaily
            )
            for item in entries where item.status.isProcessing && correctionTasks[item.id] == nil {
                startPolling(
                    entryId: item.id,
                    localDay: item.localDay ?? requestedLocalDay
                )
            }
            isLoadingDay = false
            errorMessage = error.localizedDescription
        }
    }

    /// Records a visit for LRU pruning; the snapshot itself is written by
    /// the `entries` write-through.
    private func touchDayCacheVisit(_ localDay: String) {
        dayCacheVisitOrder.removeAll { $0 == localDay }
        dayCacheVisitOrder.append(localDay)
        while dayCacheVisitOrder.count > Self.maximumCachedDays {
            let evicted = dayCacheVisitOrder.removeFirst()
            dayCache[evicted] = nil
        }
    }

    private func refreshTargetHistory() async {
        guard let profile else { return }
        guard let history = try? await supabase.fetchDailyMacroTargetHistory() else { return }
        targetHistory = history
        effectiveTarget = NutritionProgressPolicy.effectiveTarget(
            on: supabase.localDayString(for: currentDay, timezone: profile.timezone),
            history: history,
            fallback: profile.dailyMacroTarget
        )
    }

    static func targetHistoryAfterLoad(
        loaded: [DailyMacroTargetSnapshot]?,
        current: [DailyMacroTargetSnapshot]
    ) -> [DailyMacroTargetSnapshot] {
        loaded ?? current
    }

    func deleteEntry(_ entry: Entry) async {
        guard entry.canDelete else { return }
        // A local submission that never reached the server has nothing to
        // delete remotely; drop the card and its preserved payload.
        if pendingSubmissions[entry.id] != nil {
            submissionTasks[entry.id]?.cancel()
            submissionTasks[entry.id] = nil
            pendingSubmissions[entry.id] = nil
            entries.removeAll { $0.id == entry.id }
            recomputeTotals()
            return
        }
        let previousEntries = entries
        let previousTotals = todayTotals
        entries.removeAll { $0.id == entry.id }
        recomputeTotals()
        pollingTasks[entry.id]?.cancel()
        pollingTasks[entry.id] = nil
        pollingTokens[entry.id] = nil
        autoResumeRequestStates[entry.id] = nil
        resumeNotices[entry.id] = nil
        correctionSnapshots[entry.id] = nil
        correctionTasks[entry.id]?.cancel()
        correctionTasks[entry.id] = nil
        correctionPayloads[entry.id] = nil
        correctionResults[entry.id] = nil
        failedCorrections[entry.id] = nil
        resumingEntryIds.remove(entry.id)
        completionRevealEntryIds.remove(entry.id)

        do {
            try await api.deleteEntry(id: entry.id)
        } catch {
            entries = previousEntries
            todayTotals = previousTotals
            errorMessage = "Couldn’t delete that meal. Please try again."
        }
    }

    struct PendingEntrySubmission {
        let text: String?
        let audioData: Data?
        let imageJPEG: Data?
        let timezone: String
        let targetLocalDay: String
        let clientRequestId: UUID
        var placeholder: Entry
    }

    static let submissionFailedStatusMessage = "Not sent — check your connection and retry"

    /// Accepts a composed meal locally and returns immediately: the composer
    /// dismisses on the spot while the upload runs here, owned by this model
    /// rather than the sheet. A failed upload flips the placeholder card into
    /// a retryable failed state with the payload preserved — retrying re-sends
    /// the SAME clientRequestId, so an ambiguous failure can't double-log.
    @discardableResult
    func acceptEntrySubmission(
        text: String?,
        audioData: Data?,
        imageJPEG: Data?,
        for targetDay: Date? = nil,
        clientRequestId: UUID = UUID()
    ) -> UUID {
        let timezone = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier
        let day = targetDay ?? currentDay
        let targetLocalDay = supabase.localDayString(for: day, timezone: timezone)
        let placeholderId = UUID()
        let placeholder = Entry(
            id: placeholderId,
            createdAt: optimisticTimestamp(for: day, timezone: timezone),
            summary: optimisticTitle(
                text: text,
                hasAudio: audioData != nil,
                hasImage: imageJPEG != nil
            ),
            imageURL: nil,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            localDay: targetLocalDay,
            status: .queued,
            statusMessage: "Uploading"
        )

        if localDay(for: currentDay) == targetLocalDay {
            entries.insert(placeholder, at: 0)
        }
        errorMessage = nil
        Perf.mark("entry.optimistic.visible")

        pendingSubmissions[placeholderId] = PendingEntrySubmission(
            text: text,
            audioData: audioData,
            imageJPEG: imageJPEG,
            timezone: timezone,
            targetLocalDay: targetLocalDay,
            clientRequestId: clientRequestId,
            placeholder: placeholder
        )
        startSubmission(placeholderId: placeholderId)
        return placeholderId
    }

    /// Whether a timeline row is a local submission that has no server row
    /// yet (still uploading, or failed before reaching the server).
    func isPendingSubmission(_ entryId: UUID) -> Bool {
        pendingSubmissions[entryId] != nil
    }

    private func startSubmission(placeholderId: UUID) {
        guard submissionTasks[placeholderId] == nil,
              let payload = pendingSubmissions[placeholderId] else { return }
        submissionTasks[placeholderId] = Task { [weak self] in
            guard let self else { return }
            await self.runSubmission(placeholderId: placeholderId, payload: payload)
            self.submissionTasks[placeholderId] = nil
        }
    }

    private func runSubmission(
        placeholderId: UUID,
        payload: PendingEntrySubmission
    ) async {
        do {
            let result = try await api.createEntry(
                text: payload.text,
                audioData: payload.audioData,
                imageJPEG: payload.imageJPEG,
                timezone: payload.timezone,
                localDay: payload.targetLocalDay,
                clientRequestId: payload.clientRequestId
            )
            guard !Task.isCancelled else { return }
            pendingSubmissions[placeholderId] = nil
            let accepted = Entry(
                id: result.entryId,
                createdAt: payload.placeholder.createdAt,
                summary: payload.placeholder.summary,
                imageURL: nil,
                proteinG: 0,
                carbsG: 0,
                fatG: 0,
                caloriesKcal: 0,
                localDay: payload.targetLocalDay,
                status: result.status,
                statusMessage: result.status.defaultMessage,
                statusUpdatedAt: Date()
            )

            if entries.contains(where: { $0.id == result.entryId }) {
                // A reload already fetched the server row (an earlier attempt
                // landed but its response was lost); drop the placeholder
                // instead of duplicating the id.
                entries.removeAll { $0.id == placeholderId }
            } else if let index = entries.firstIndex(where: { $0.id == placeholderId }) {
                entries[index] = accepted
            } else if localDay(for: currentDay) == payload.targetLocalDay {
                entries.insert(accepted, at: 0)
            } else if var cachedDay = dayCache[payload.targetLocalDay] {
                // Not the visible day: keep that day's snapshot current so a
                // revisit shows the new meal before its refresh lands.
                cachedDay.removeAll { $0.id == placeholderId }
                cachedDay.insert(accepted, at: 0)
                dayCache[payload.targetLocalDay] = cachedDay
            }
            recomputeTotals()
            startPolling(entryId: result.entryId, localDay: payload.targetLocalDay)
        } catch {
            guard !Task.isCancelled else { return }
            var failed = payload.placeholder
            failed.status = .failed
            failed.statusMessage = Self.submissionFailedStatusMessage
            failed.errorMessage = Self.submissionErrorMessage(error)
            failed.statusUpdatedAt = Date()
            pendingSubmissions[placeholderId]?.placeholder = failed
            if let index = entries.firstIndex(where: { $0.id == placeholderId }) {
                entries[index] = failed
            } else if var cachedDay = dayCache[payload.targetLocalDay],
                      let index = cachedDay.firstIndex(where: { $0.id == placeholderId }) {
                cachedDay[index] = failed
                dayCache[payload.targetLocalDay] = cachedDay
            }
            recomputeTotals()
        }
    }

    static func submissionErrorMessage(_ error: Error) -> String {
        if let apiError = error as? APIService.APIError {
            return apiError.localizedDescription
        }
        if error is URLError {
            return "Couldn’t reach the server. Check your connection and try again."
        }
        return "The meal wasn’t sent. Please try again."
    }

    func retryEntry(_ entry: Entry) async {
        guard entry.status == .failed else { return }
        // A failed local submission retries by re-sending its preserved
        // payload (same clientRequestId — the server dedupes), not by asking
        // the server to resume a row that never existed.
        if pendingSubmissions[entry.id] != nil {
            guard submissionTasks[entry.id] == nil else { return }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].status = .queued
                entries[index].statusMessage = "Uploading"
                entries[index].errorMessage = nil
                entries[index].statusUpdatedAt = Date()
                pendingSubmissions[entry.id]?.placeholder = entries[index]
            }
            startSubmission(placeholderId: entry.id)
            return
        }
        let targetLocalDay = entry.localDay ?? localDay(for: currentDay)
        let outcome = await requestResume(
            entry: entry,
            targetLocalDay: targetLocalDay,
            automatic: false
        )
        if case .accepted = outcome {
            startPolling(entryId: entry.id, localDay: targetLocalDay, restart: true)
        }
    }

    /// Starts a meal correction the moment the composer accepts it locally.
    /// The visible card flips into "Updating nutrition estimate" immediately
    /// and the request runs here, detached from any sheet or pushed screen, so
    /// dismissing them never abandons or blocks the update.
    @discardableResult
    func submitCorrection(entryId: UUID, submission: EntryCorrectionSubmission) -> Bool {
        guard correctionTasks[entryId] == nil else { return false }
        if let index = entries.firstIndex(where: { $0.id == entryId }) {
            guard entries[index].status == .complete else { return false }
            correctionSnapshots[entryId] = entries[index]
            entries[index] = EntryCorrectionPresentation.processingEntry(from: entries[index])
        }
        failedCorrections[entryId] = nil
        correctionResults[entryId] = nil
        correctionPayloads[entryId] = submission
        correctionTasks[entryId] = Task { [weak self] in
            guard let self else { return }
            await self.runCorrection(entryId: entryId, payload: submission)
            self.correctionTasks[entryId] = nil
        }
        return true
    }

    /// Re-submits the preserved correction with its original client request
    /// id, so a retry after an ambiguous failure replays idempotently instead
    /// of applying the correction twice.
    func retryCorrection(entryId: UUID) {
        guard let payload = correctionPayloads[entryId] else { return }
        submitCorrection(entryId: entryId, submission: payload)
    }

    func dismissFailedCorrection(entryId: UUID) {
        guard correctionTasks[entryId] == nil else { return }
        failedCorrections[entryId] = nil
        correctionPayloads[entryId] = nil
    }

    func activeCorrectionTask(entryId: UUID) -> Task<Void, Never>? {
        correctionTasks[entryId]
    }

    func activeSubmissionTask(entryId: UUID) -> Task<Void, Never>? {
        submissionTasks[entryId]
    }

    private func runCorrection(entryId: UUID, payload: EntryCorrectionSubmission) async {
        do {
            let result = try await reanalysis.correctEntry(
                id: entryId,
                text: payload.text,
                audioData: payload.audioData,
                clientRequestId: payload.clientRequestId
            )
            guard result.status != .failed else {
                throw APIService.APIError.server(
                    statusCode: 409,
                    message: "The correction couldn’t be applied. Try again."
                )
            }
            guard !Task.isCancelled else { return }
            let refreshed = try? await fetchEntryById(entryId)
            guard !Task.isCancelled else { return }
            if let refreshed, refreshed.status == .complete {
                applyCorrectionSuccess(entryId: entryId, refreshed: refreshed)
            } else {
                finishCorrectionViaPolling(entryId: entryId)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            applyCorrectionFailure(entryId: entryId, message: Self.submissionErrorMessage(error))
        }
    }

    private func applyCorrectionSuccess(entryId: UUID, refreshed: Entry) {
        correctionPayloads[entryId] = nil
        correctionSnapshots[entryId] = nil
        failedCorrections[entryId] = nil
        // Kept until a reload's rows demonstrably include the correction, so
        // a fetch that raced the server update can't resurface stale values.
        correctionResults[entryId] = refreshed
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        if Self.shouldRevealCompletedAnalysis(
            previous: entries[index].status,
            refreshed: refreshed.status
        ) {
            completionRevealEntryIds.insert(entryId)
        }
        entries[index] = refreshed
        recomputeTotals()
    }

    private func applyCorrectionFailure(entryId: UUID, message: String) {
        let rollback = correctionSnapshots.removeValue(forKey: entryId)
        failedCorrections[entryId] = message
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        if let rollback {
            entries[index] = rollback
        }
        recomputeTotals()
    }

    /// The server accepted the correction but the follow-up fetch failed;
    /// hand the card to the existing polling machinery, which settles it from
    /// the now-final server row instead of guessing.
    private func finishCorrectionViaPolling(entryId: UUID) {
        correctionPayloads[entryId] = nil
        failedCorrections[entryId] = nil
        let day = entries.first(where: { $0.id == entryId })?.localDay
            ?? localDay(for: currentDay)
        startPolling(entryId: entryId, localDay: day, restart: true)
    }

    private func startPolling(entryId: UUID, localDay: String, restart: Bool = false) {
        if !restart, pollingTasks[entryId] != nil { return }
        pollingTasks[entryId]?.cancel()
        let token = UUID()
        pollingTokens[entryId] = token
        pollingTasks[entryId] = Task { [weak self] in
            guard let self else { return }
            await self.poll(entryId: entryId, targetLocalDay: localDay)
            if self.pollingTokens[entryId] == token {
                self.pollingTasks[entryId] = nil
                self.pollingTokens[entryId] = nil
            }
        }
    }

    private func poll(entryId: UUID, targetLocalDay: String) async {
        var deadline = Date().addingTimeInterval(600)
        var delay = Self.streamingPreviewPollingInterval
        var consecutiveErrors = 0
        var observedStatus: EntryStatus?

        while !Task.isCancelled && Date() < deadline {
            do {
                // Steady-state polls use a slim status projection. Any status
                // transition (queued → transcribing → analyzing → terminal)
                // triggers one full fetch, because the server also rewrites
                // row content (transcript into raw_text, final macros, image)
                // exactly at those boundaries.
                guard let snapshot = try await supabase.fetchEntryStatus(id: entryId) else {
                    throw URLError(.cannotParseResponse)
                }
                guard !Task.isCancelled else { return }

                var refreshed: Entry
                if snapshot.status.isProcessing,
                   let existing = entries.first(where: { $0.id == entryId }),
                   existing.status == snapshot.status {
                    refreshed = Self.entryApplyingStatusSnapshot(to: existing, snapshot: snapshot)
                } else {
                    guard let full = try await supabase.fetchEntry(id: entryId) else {
                        throw URLError(.cannotParseResponse)
                    }
                    guard !Task.isCancelled else { return }
                    refreshed = full
                }
                consecutiveErrors = 0
                observedStatus = refreshed.status

                if refreshed.status == .complete {
                    resumeNotices[entryId] = nil
                } else if let notice = resumeNotices[entryId] {
                    refreshed.statusMessage = notice
                }

                if refreshed.status == .failed,
                   let rollback = correctionSnapshots.removeValue(forKey: entryId) {
                    correctionPayloads[entryId] = nil
                    if localDay(for: currentDay) == targetLocalDay,
                       let index = entries.firstIndex(where: { $0.id == entryId }) {
                        entries[index] = rollback
                        recomputeTotals()
                        errorMessage = EntryCorrectionPresentation.rollbackMessage
                    }
                    autoResumeRequestStates[entryId] = nil
                    return
                }

                if localDay(for: currentDay) == targetLocalDay {
                    let isCorrection = correctionSnapshots[entryId] != nil
                    if let index = entries.firstIndex(where: { $0.id == entryId }) {
                        if Self.shouldRevealCompletedAnalysis(
                            previous: entries[index].status,
                            refreshed: refreshed.status
                        ) {
                            completionRevealEntryIds.insert(entryId)
                        }
                        entries[index] = refreshed
                    } else {
                        entries.insert(refreshed, at: 0)
                    }
                    if !isCorrection || refreshed.status == .complete {
                        recomputeTotals()
                    }
                }

                if refreshed.status == .complete || refreshed.status == .failed {
                    correctionSnapshots[entryId] = nil
                    correctionPayloads[entryId] = nil
                    autoResumeRequestStates[entryId] = nil
                    return
                }

                let observedAttempt = refreshed.processingAttempts
                if Self.shouldAutoResume(
                    refreshed,
                    at: Date(),
                    requestState: autoResumeRequestStates[entryId]
                ) {
                    autoResumeRequestStates[entryId] = AutoResumeRequestState(
                        attempt: observedAttempt,
                        retryAfter: nil
                    )
                    let outcome = await requestResume(
                        entry: refreshed,
                        targetLocalDay: targetLocalDay,
                        automatic: true
                    )
                    guard !Task.isCancelled else {
                        if autoResumeRequestStates[entryId]?.attempt == observedAttempt {
                            autoResumeRequestStates[entryId] = nil
                        }
                        return
                    }
                    switch outcome {
                    case .accepted:
                        // resume_entry intentionally returns 202 after the row is
                        // durable even when its nested worker dispatch did not
                        // land. If the database attempt remains unchanged, allow
                        // one bounded redispatch instead of suppressing that
                        // attempt forever.
                        if autoResumeRequestStates[entryId]?.attempt == observedAttempt {
                            autoResumeRequestStates[entryId] = Self.autoResumeRetryState(
                                forAttempt: observedAttempt,
                                scheduledAt: Date()
                            )
                        }
                        deadline = Date().addingTimeInterval(600)
                        delay = Self.streamingPreviewPollingInterval
                    case .failed:
                        if autoResumeRequestStates[entryId]?.attempt == observedAttempt {
                            autoResumeRequestStates[entryId] = Self.autoResumeRetryState(
                                forAttempt: observedAttempt,
                                scheduledAt: Date()
                            )
                        }
                    case .conflict:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                consecutiveErrors += 1
                if consecutiveErrors >= 12 {
                    updateStatusMessage(
                        entryId: entryId,
                        targetLocalDay: targetLocalDay,
                        message: "Can’t refresh — pull to try again"
                    )
                    return
                }
            }

            let sleepDelay = observedStatus == .analyzing
                ? Self.streamingPreviewPollingInterval
                : delay
            try? await Task.sleep(nanoseconds: sleepDelay)
            guard !Task.isCancelled else { return }
            delay = Self.nextPollingDelay(
                current: sleepDelay,
                status: observedStatus
            )
        }

        guard !Task.isCancelled else { return }
        if resumeNotices[entryId] == nil {
            updateStatusMessage(
                entryId: entryId,
                targetLocalDay: targetLocalDay,
                message: "Still working in the background"
            )
        }
    }

    @discardableResult
    private func requestResume(
        entry: Entry,
        targetLocalDay: String,
        automatic: Bool
    ) async -> ResumeRequestOutcome {
        guard !resumingEntryIds.contains(entry.id) else { return .conflict }
        guard automatic || entry.processingAttempts < Self.maximumProcessingAttempts else {
            let message = "Retry limit reached — log it again"
            resumeNotices[entry.id] = message
            updateStatusMessage(entryId: entry.id, targetLocalDay: targetLocalDay, message: message)
            return .conflict
        }

        resumingEntryIds.insert(entry.id)
        updateStatusMessage(
            entryId: entry.id,
            targetLocalDay: targetLocalDay,
            message: automatic ? "Restarting stalled analysis" : "Requesting retry"
        )
        defer { resumingEntryIds.remove(entry.id) }

        do {
            let result = try await api.resumeEntry(id: entry.id)
            guard !Task.isCancelled else { return .failed }
            switch result {
            case .accepted(let status):
                resumeNotices[entry.id] = nil
                if localDay(for: currentDay) == targetLocalDay,
                   let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index].status = status
                    entries[index].statusMessage = status.defaultMessage
                    entries[index].errorMessage = nil
                    entries[index].analysisPreview = nil
                    entries[index].statusUpdatedAt = Date()
                    entries[index].processingAttempts = min(
                        Self.maximumProcessingAttempts,
                        max(entries[index].processingAttempts, entry.processingAttempts) + 1
                    )
                    recomputeTotals()
                }
                return .accepted

            case .conflict(let serverMessage):
                let message = Self.resumeConflictMessage(
                    serverMessage,
                    automatic: automatic
                )
                resumeNotices[entry.id] = message
                updateStatusMessage(entryId: entry.id, targetLocalDay: targetLocalDay, message: message)
                return .conflict
            }
        } catch {
            guard !Task.isCancelled else { return .failed }
            let message = automatic
                ? "Couldn’t restart — still checking"
                : "Couldn’t retry — check your connection"
            resumeNotices[entry.id] = message
            updateStatusMessage(entryId: entry.id, targetLocalDay: targetLocalDay, message: message)
            return .failed
        }
    }

    static func shouldAutoResume(
        _ entry: Entry,
        at now: Date,
        requestState: AutoResumeRequestState?
    ) -> Bool {
        guard entry.status.isProcessing,
              entry.processingAttempts <= maximumProcessingAttempts else { return false }
        let lastUpdate = entry.statusUpdatedAt ?? entry.createdAt
        guard now.timeIntervalSince(lastUpdate) >= staleResumeInterval else { return false }
        guard let requestState,
              requestState.attempt == entry.processingAttempts else { return true }
        guard let retryAfter = requestState.retryAfter else { return false }
        return now >= retryAfter
    }

    static func autoResumeRetryState(
        forAttempt attempt: Int,
        scheduledAt: Date
    ) -> AutoResumeRequestState {
        AutoResumeRequestState(
            attempt: attempt,
            retryAfter: scheduledAt.addingTimeInterval(autoResumeRetryInterval)
        )
    }

    static func shouldRevealCompletedAnalysis(
        previous: EntryStatus?,
        refreshed: EntryStatus
    ) -> Bool {
        previous?.isProcessing == true && refreshed == .complete
    }

    /// Applies a slim status snapshot onto the currently visible entry,
    /// keeping locally known fields (summary, timestamps, image) that the
    /// status projection intentionally omits while the meal processes.
    nonisolated static func entryApplyingStatusSnapshot(
        to current: Entry,
        snapshot: SupabaseService.EntryStatusSnapshot
    ) -> Entry {
        var updated = current
        updated.status = snapshot.status
        updated.statusMessage = snapshot.statusMessage
        updated.analysisPreview = snapshot.analysisPreview
        updated.errorMessage = snapshot.errorMessage
        updated.processingAttempts = snapshot.processingAttempts
        updated.statusUpdatedAt = snapshot.statusUpdatedAt
        if let localDay = snapshot.localDay {
            updated.localDay = localDay
        }
        return updated
    }

    static func nextPollingDelay(
        current: UInt64,
        status: EntryStatus?
    ) -> UInt64 {
        if status == .analyzing { return streamingPreviewPollingInterval }
        return min(current + current / 2, maximumPollingInterval)
    }

    static func shouldAdvancePinnedDay(
        currentDay: Date,
        now: Date,
        timezone: String,
        wasPinnedToToday: Bool
    ) -> Bool {
        guard wasPinnedToToday else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        return !calendar.isDate(currentDay, inSameDayAs: now)
    }

    func consumeCompletionReveal(for entryId: UUID) {
        completionRevealEntryIds.remove(entryId)
    }

    static func resumeConflictMessage(_ message: String, automatic: Bool) -> String {
        let normalized = message.lowercased()
        if normalized.contains("never finished uploading") {
            return "Attachment upload incomplete — delete and log it again"
        }
        if normalized.contains("attempt")
            || normalized.contains("exhaust")
            || normalized.contains("limit")
            || normalized.contains("could not be recovered")
            || normalized.contains("log it again") {
            return "Retry limit reached — log it again"
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return automatic ? "Couldn’t restart — still checking" : "Retry unavailable right now"
        }
        return automatic ? trimmed : "Retry unavailable — \(trimmed)"
    }

    private func updateStatusMessage(entryId: UUID, targetLocalDay: String, message: String) {
        guard localDay(for: currentDay) == targetLocalDay,
              let index = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[index].statusMessage = message
    }

    private func localDay(for date: Date) -> String {
        supabase.localDayString(
            for: date,
            timezone: profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier
        )
    }

    private func isToday(_ date: Date, timezone: String) -> Bool {
        supabase.localDayString(for: date, timezone: timezone)
            == supabase.localDayString(for: Date(), timezone: timezone)
    }

    private func optimisticTimestamp(for day: Date, timezone: String) -> Date {
        if isToday(day, timezone: timezone) { return Date() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private func optimisticTitle(text: String?, hasAudio: Bool, hasImage: Bool) -> String {
        if let first = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .first,
           !first.isEmpty {
            return first
        }
        if hasAudio && hasImage { return "Voice note + photo" }
        if hasAudio { return "Voice note" }
        if hasImage { return "Meal photo" }
        return "Meal"
    }

    static func totals(for entries: [Entry], correctionsInFlight: Set<UUID> = []) -> DayTotals {
        entries.reduce(.empty) { totals, entry in
            // A meal whose estimate is being corrected keeps its previous
            // macros on the card; keep them in the daily summary too so the
            // day's numbers don't dip and jump while the update runs.
            let countsWhileUpdating = correctionsInFlight.contains(entry.id)
                && entry.status.isProcessing
            guard entry.status == .complete || countsWhileUpdating else { return totals }
            return DayTotals(
                proteinG: totals.proteinG + entry.proteinG,
                carbsG: totals.carbsG + entry.carbsG,
                fatG: totals.fatG + entry.fatG,
                caloriesKcal: totals.caloriesKcal + entry.caloriesKcal
            )
        }
    }

    private func recomputeTotals() {
        todayTotals = Self.totals(
            for: entries,
            correctionsInFlight: Set(correctionSnapshots.keys)
        )
    }

    struct CorrectionLoadMerge: Equatable {
        var entries: [Entry]
        var refreshedSnapshots: [UUID: Entry]
        var reflectedResultIds: Set<UUID>
    }

    /// Reconciles freshly loaded rows with local correction state: rows whose
    /// correction is still running go back into the processing presentation,
    /// and rows read before the server finalized a completed correction are
    /// overlaid with the known result instead of flashing stale values.
    nonisolated static func mergedEntriesAfterLoad(
        fetched: [Entry],
        inFlightCorrectionIds: Set<UUID>,
        correctionResults: [UUID: Entry],
        at date: Date = Date()
    ) -> CorrectionLoadMerge {
        var merged = fetched
        var refreshedSnapshots: [UUID: Entry] = [:]
        var reflectedResultIds: Set<UUID> = []
        for index in merged.indices {
            let id = merged[index].id
            if let corrected = correctionResults[id] {
                if EntryCorrectionPresentation.serverRowReflectsCorrection(
                    fetched: merged[index],
                    corrected: corrected
                ) {
                    reflectedResultIds.insert(id)
                } else {
                    merged[index] = corrected
                }
            }
            if inFlightCorrectionIds.contains(id), merged[index].status == .complete {
                refreshedSnapshots[id] = merged[index]
                merged[index] = EntryCorrectionPresentation.processingEntry(
                    from: merged[index],
                    at: date
                )
            }
        }
        return CorrectionLoadMerge(
            entries: merged,
            refreshedSnapshots: refreshedSnapshots,
            reflectedResultIds: reflectedResultIds
        )
    }

    private func reapplyCorrectionStateAfterLoad() {
        let merge = Self.mergedEntriesAfterLoad(
            fetched: entries,
            inFlightCorrectionIds: Set(correctionTasks.keys),
            correctionResults: correctionResults
        )
        entries = merge.entries
        for (id, snapshot) in merge.refreshedSnapshots {
            correctionSnapshots[id] = snapshot
        }
        for id in merge.reflectedResultIds {
            correctionResults[id] = nil
        }
        // A correction that already settled (for example via the polling
        // fallback that this load canceled) leaves no task behind; its
        // snapshot is stale once the visible row is terminal again.
        for id in correctionSnapshots.keys where correctionTasks[id] == nil {
            if let row = entries.first(where: { $0.id == id }), !row.status.isProcessing {
                correctionSnapshots[id] = nil
            }
        }
        // Local submissions have no server row yet; re-overlay them so a
        // reload can't drop a meal that is still uploading or awaiting retry.
        for (id, payload) in pendingSubmissions
        where payload.targetLocalDay == currentLocalDay
            && !entries.contains(where: { $0.id == id }) {
            entries.insert(payload.placeholder, at: 0)
        }
    }

    static func visibleStateAfterLoadFailure(
        previousEntries: [Entry],
        previousTotals: DayTotals,
        visibleLocalDay: String,
        requestedLocalDay: String
    ) -> (entries: [Entry], totals: DayTotals) {
        guard visibleLocalDay == requestedLocalDay else { return ([], .empty) }
        return (previousEntries, previousTotals)
    }
}
