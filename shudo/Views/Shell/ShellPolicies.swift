import Foundation

/// Spots meals that just finished analyzing (seen processing, now complete)
/// so the shell can tell the coach (`coach_sync` trigger `meal_complete`).
struct MealCompletionTracker: Equatable {
    private(set) var processing: Set<UUID> = []

    /// Feed every published entry list; returns ids that completed since the
    /// previous call.
    mutating func observe(_ entries: [Entry]) -> [UUID] {
        var completed: [UUID] = []
        var stillProcessing = Set<UUID>()
        for entry in entries {
            if entry.status.isProcessing {
                stillProcessing.insert(entry.id)
            } else if entry.status == .complete, processing.contains(entry.id) {
                completed.append(entry.id)
            }
        }
        processing = stillProcessing
        return completed
    }
}

/// When the coach thread counts as "on screen" (banners are suppressed and
/// the thread refreshes instead).
enum CoachPresencePolicy {
    static func isThreadVisible(tab: AppTab, sceneActive: Bool, isPresentingOverThread: Bool) -> Bool {
        tab == .today && sceneActive && !isPresentingOverThread
    }
}
