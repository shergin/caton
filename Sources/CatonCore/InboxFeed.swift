import Foundation

/// The threads Caton is holding, and the rules for folding a poll into them.
///
/// A poll that changed anything also drops read threads older than four
/// read-windows. Unread threads stay: GitHub is still delivering them.
/// An unchanged poll (two 304s) leaves the set exactly as it was.
public enum InboxFeed {
    /// How far back the read-not-done window reaches.
    public static let recentWindow: TimeInterval = 7 * 24 * 3600
    /// Read threads are kept for this many read-windows, then forgotten.
    static let retainedWindows = 4

    /// Folds one poll into `threads`. `changed` is false only when both
    /// feeds answered that nothing changed; a changed feed always counts,
    /// even when its threads match what was already held.
    public static func merge(
        _ threads: [String: NotificationThread],
        unread: FeedPoll,
        recent: FeedPoll,
        now: Date,
        recentWindow: TimeInterval = recentWindow
    ) -> (threads: [String: NotificationThread], changed: Bool) {
        var threads = threads
        var changed = false
        if case .changed(let unreadThreads) = unread {
            let unreadIDs = Set(unreadThreads.map(\.id))
            // Unread here but not in the feed: read elsewhere, or done elsewhere.
            for (id, thread) in threads where thread.isUnread && !unreadIDs.contains(id) {
                threads[id]?.isUnread = false
            }
            for thread in unreadThreads { threads[thread.id] = thread }
            changed = true
        }
        if case .changed(let recentThreads) = recent {
            for thread in recentThreads {
                // The unread feed is authoritative for unread state when both have the thread.
                if let existing = threads[thread.id], existing.isUnread, !thread.isUnread, existing.updatedAt > thread.updatedAt { continue }
                threads[thread.id] = thread
            }
            changed = true
        }
        guard changed else { return (threads, false) }
        let horizon = now.addingTimeInterval(-TimeInterval(retainedWindows) * recentWindow)
        threads = threads.filter { $0.value.isUnread || $0.value.updatedAt > horizon }
        return (threads, true)
    }
}
