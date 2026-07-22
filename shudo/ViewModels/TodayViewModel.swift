import Foundation
import UIKit

@MainActor
final class TodayViewModel: ObservableObject {
    @Published var profile: Profile?
    @Published private(set) var todayTotals: DayTotals = .empty
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var currentDay: Date = Date()
    @Published var isPresentingComposer = false
    @Published var errorMessage: String?
    @Published private(set) var isPinnedToToday = true
    @Published private(set) var isLoadingDay = false
    @Published private(set) var resumingEntryIds: Set<UUID> = []
    @Published private(set) var completionRevealEntryIds: Set<UUID> = []
    @Published private(set) var effectiveTarget: MacroTarget

    let api: APIService
    let supabase: SupabaseService

    private var loadGeneration = UUID()
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private var pollingTokens: [UUID: UUID] = [:]
    private var autoResumeRequestStates: [UUID: AutoResumeRequestState] = [:]
    private var resumeNotices: [UUID: String] = [:]
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

    init(profile: Profile, api: APIService, supabase: SupabaseService = SupabaseService()) {
        self.api = api
        self.supabase = supabase
        self.profile = profile
        self.effectiveTarget = profile.dailyMacroTarget
        Task { await load(day: Date()) }
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
        isPinnedToToday = isToday(day, timezone: timezone)
        isLoadingDay = true
        errorMessage = nil

        do {
            async let entryRequest = supabase.fetchEntries(for: day, timezone: timezone)
            async let targetRequest = supabase.fetchDailyMacroTargetHistory()
            let (items, loadedTargetHistory) = try await (entryRequest, targetRequest)
            guard loadGeneration == generation else { return }
            targetHistory = loadedTargetHistory
            entries = items
            todayTotals = Self.totals(for: items)
            effectiveTarget = NutritionProgressPolicy.effectiveTarget(
                on: requestedLocalDay,
                history: targetHistory,
                fallback: profile?.dailyMacroTarget ?? .defaultDaily
            )
            isLoadingDay = false

            for item in items where item.status.isProcessing {
                startPolling(entryId: item.id, localDay: item.localDay ?? localDay(for: day))
            }
        } catch {
            guard loadGeneration == generation else { return }
            let fallback = Self.visibleStateAfterLoadFailure(
                previousEntries: previouslyVisibleEntries,
                previousTotals: previouslyVisibleTotals,
                visibleLocalDay: visibleLocalDay,
                requestedLocalDay: requestedLocalDay
            )
            entries = fallback.entries
            todayTotals = fallback.totals
            effectiveTarget = NutritionProgressPolicy.effectiveTarget(
                on: requestedLocalDay,
                history: targetHistory,
                fallback: profile?.dailyMacroTarget ?? .defaultDaily
            )
            for item in entries where item.status.isProcessing {
                startPolling(
                    entryId: item.id,
                    localDay: item.localDay ?? requestedLocalDay
                )
            }
            isLoadingDay = false
            errorMessage = error.localizedDescription
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

    func deleteEntry(_ entry: Entry) async {
        guard entry.canDelete else { return }
        let previousEntries = entries
        let previousTotals = todayTotals
        entries.removeAll { $0.id == entry.id }
        todayTotals = Self.totals(for: entries)
        pollingTasks[entry.id]?.cancel()
        pollingTasks[entry.id] = nil
        pollingTokens[entry.id] = nil
        autoResumeRequestStates[entry.id] = nil
        resumeNotices[entry.id] = nil
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

    @discardableResult
    func submitEntry(
        text: String?,
        audioData: Data?,
        image: UIImage?,
        for targetDay: Date? = nil,
        clientRequestId: UUID = UUID()
    ) async -> Bool {
        let timezone = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier
        let day = targetDay ?? currentDay
        let targetLocalDay = supabase.localDayString(for: day, timezone: timezone)
        let temporaryId = UUID()
        let placeholder = Entry(
            id: temporaryId,
            createdAt: optimisticTimestamp(for: day, timezone: timezone),
            summary: optimisticTitle(text: text, hasAudio: audioData != nil, hasImage: image != nil),
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

        do {
            let result = try await api.createEntry(
                text: text,
                audioData: audioData,
                image: image,
                timezone: timezone,
                localDay: targetLocalDay,
                clientRequestId: clientRequestId
            )
            let accepted = Entry(
                id: result.entryId,
                createdAt: placeholder.createdAt,
                summary: placeholder.summary,
                imageURL: nil,
                proteinG: 0,
                carbsG: 0,
                fatG: 0,
                caloriesKcal: 0,
                localDay: targetLocalDay,
                status: result.status,
                statusMessage: result.status.defaultMessage,
                statusUpdatedAt: Date()
            )

            if let index = entries.firstIndex(where: { $0.id == temporaryId }) {
                entries[index] = accepted
            } else if localDay(for: currentDay) == targetLocalDay {
                entries.insert(accepted, at: 0)
            }
            todayTotals = Self.totals(for: entries)
            startPolling(entryId: result.entryId, localDay: targetLocalDay)
            return true
        } catch {
            entries.removeAll { $0.id == temporaryId }
            todayTotals = Self.totals(for: entries)
            errorMessage = error.localizedDescription
            return false
        }
    }

    func retryEntry(_ entry: Entry) async {
        guard entry.status == .failed else { return }
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
                guard var refreshed = try await supabase.fetchEntry(id: entryId) else {
                    throw URLError(.cannotParseResponse)
                }
                guard !Task.isCancelled else { return }
                consecutiveErrors = 0
                observedStatus = refreshed.status

                if refreshed.status == .complete {
                    resumeNotices[entryId] = nil
                } else if let notice = resumeNotices[entryId] {
                    refreshed.statusMessage = notice
                }

                if localDay(for: currentDay) == targetLocalDay {
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
                    todayTotals = Self.totals(for: entries)
                }

                if refreshed.status == .complete || refreshed.status == .failed {
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
                    todayTotals = Self.totals(for: entries)
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

    static func totals(for entries: [Entry]) -> DayTotals {
        entries.reduce(.empty) { totals, entry in
            guard entry.status == .complete else { return totals }
            return DayTotals(
                proteinG: totals.proteinG + entry.proteinG,
                carbsG: totals.carbsG + entry.carbsG,
                fatG: totals.fatG + entry.fatG,
                caloriesKcal: totals.caloriesKcal + entry.caloriesKcal
            )
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
