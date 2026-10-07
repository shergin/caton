import Foundation

/// Which reminders join Needs me, and which have finished.
///
/// A reminder whose pull request was answered is finished. So is one whose
/// pull request is no longer open, once the whole list is known. A reminder
/// on a pull request that has not loaded yet is kept: it is never dropped
/// for want of data.
public enum FollowUps {
    /// One reminder and what is known about its pull request.
    public struct Known: Sendable {
        public var id: String
        public var followUp: FollowUp
        /// The latest review or comment from someone else, when the pull request is loaded.
        public var lastResponse: Date?
        /// The open-pull-request list is complete and this one is not in it.
        public var isGone: Bool

        public init(id: String, followUp: FollowUp, lastResponse: Date?, isGone: Bool) {
            self.id = id
            self.followUp = followUp
            self.lastResponse = lastResponse
            self.isGone = isGone
        }
    }

    /// The rows to show, and the reminders to forget.
    public struct Resolution: Equatable, Sendable {
        public var due: [InboxItem]
        public var drop: [String]

        public init(due: [InboxItem] = [], drop: [String] = []) {
            self.due = due
            self.drop = drop
        }
    }

    public static func resolve(_ known: some Sequence<Known>, now: Date) -> Resolution {
        var resolution = Resolution()
        for entry in known {
            if entry.isGone {
                resolution.drop.append(entry.id)
                continue
            }
            switch entry.followUp.outcome(lastResponse: entry.lastResponse, now: now) {
            case .waiting:
                continue
            case .answered:
                resolution.drop.append(entry.id)
            case .due:
                resolution.due.append(row(for: entry))
            }
        }
        return resolution
    }

    private static func row(for entry: Known) -> InboxItem {
        let followUp = entry.followUp
        let thread = NotificationThread(
            id: entry.id,
            repository: followUp.repository,
            kind: .pullRequest,
            number: followUp.number,
            title: followUp.title,
            reason: .author,
            isUnread: true,
            updatedAt: followUp.until,
            webURL: followUp.url
        )
        let when = followUp.until.formatted(date: .abbreviated, time: .shortened)
        let classification = Classification(
            split: .needsMe,
            badge: .followUp,
            because: "You asked to be reminded if nobody had reviewed or commented by \(when), and nobody has."
        )
        return InboxItem(id: .followUp(entry.id), thread: thread, classification: classification, isUnread: true, resurfacing: .noActivity)
    }
}
