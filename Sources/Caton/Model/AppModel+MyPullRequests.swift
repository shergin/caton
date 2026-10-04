import AppKit
import CatonCore

/// My PRs: the viewer's own open pull requests, read from the handle the
/// subject store shares with `MyPullRequestsView`, and the reminders set on
/// them. A reminder that comes due with no answer joins Needs me.
extension AppModel {
    static let followUpPrefix = "followup:"

    /// The pull requests in the order the view shows them, for the keyboard.
    var myPullRequestNodes: [MyPullRequests.Node] {
        guard let handle = subjects?.myPullRequests, case .ready(let data) = handle.phase else { return [] }
        return MyPullRequests.groups(data.viewer.myPullRequestList, now: .now).flatMap(\.nodes)
    }

    func myPullRequestNode(_ id: String) -> MyPullRequests.Node? { myPullRequestNodes.first { $0.id == id } }

    private func node(_ id: String) -> MyPullRequests.Node? { myPullRequestNode(id) }

    var viewerLogin: String {
        if case .signedIn(let viewer) = account { return viewer.login }
        return ""
    }

    func followUp(for id: String) -> FollowUp? {
        _ = settingsVersion
        return state.followUps[id]
    }

    func openPullRequest(_ id: String? = nil) {
        guard let id = id ?? selectedID, let url = node(id).flatMap({ URL(string: $0.url) }) else { return }
        select(id)
        openURL(url)
    }

    func copyPullRequestLink(_ id: String? = nil) {
        guard let id = id ?? selectedID, let node = node(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url, forType: .string)
        toast("Copied \(node.myPullRequestRow.repository.nameWithOwner)#\(node.myPullRequestRow.number)")
    }

    /// Opens the picker for a reminder on a pull request.
    func beginReminder(_ id: String? = nil) {
        guard let id = id ?? selectedID, node(id) != nil else { return }
        select(id)
        snoozeTarget = .pullRequest(id)
        overlay = .snooze
    }

    /// Reminds about a pull request at `until` unless someone reviews or
    /// comments first.
    func remind(_ id: String, until: Date) {
        guard let node = node(id) else { return }
        let row = node.myPullRequestRow
        let parts = row.repository.nameWithOwner.split(separator: "/").map(String.init)
        guard parts.count == 2, let url = URL(string: node.url) else { return }
        let previous = state.followUps[id]
        state.followUps[id] = FollowUp(
            until: until,
            answeredAt: MyPullRequests.status(node.pullRequestStanding).lastResponse(excluding: viewerLogin),
            repository: RepositoryName(owner: parts[0], name: parts[1]),
            number: row.number,
            title: row.title,
            url: url
        )
        undoStack.append(.followUps([id: previous]))
        settingsVersion += 1
        toast("Reminding \(until.formatted(.relative(presentation: .named))) if nobody answers · z to undo")
        recompute()
    }

    /// What a choice in the snooze picker does: snooze the threads, or set
    /// the reminder on a pull request.
    func chooseSnooze(_ until: Date) {
        overlay = .none
        switch snoozeTarget {
        case .threads: snooze(until: until, onlyIfQuiet: snoozeOnlyIfQuiet)
        case .pullRequest(let id): remind(id, until: until)
        }
    }

    func clearReminder(_ id: String) {
        guard let previous = state.followUps.removeValue(forKey: id) else { return }
        undoStack.append(.followUps([id: previous]))
        settingsVersion += 1
        toast("Reminder removed · z to undo")
        recompute()
    }

    /// Reminders that came due unanswered, as Needs me rows. A reminder whose
    /// pull request got an answer is dropped; one on a pull request that is
    /// no longer open is too, once the whole list is known.
    func dueReminders(now: Date) -> [InboxItem] {
        guard !state.followUps.isEmpty, !isPractice else { return [] }
        var loaded: [String: MyPullRequests.Node]?
        var complete = false
        if let handle = subjects?.myPullRequests, case .ready(let data) = handle.phase {
            let list = data.viewer.myPullRequestList
            loaded = Dictionary(list.pullRequests.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            complete = !list.pullRequests.hasNext
        }
        var items: [InboxItem] = []
        for (id, followUp) in state.followUps {
            let node = loaded?[id]
            if node == nil, complete {
                state.followUps[id] = nil
                continue
            }
            let lastResponse = node.flatMap { MyPullRequests.status($0.pullRequestStanding).lastResponse(excluding: viewerLogin) }
            switch followUp.outcome(lastResponse: lastResponse, now: now) {
            case .waiting:
                continue
            case .answered:
                state.followUps[id] = nil
            case .due:
                let thread = NotificationThread(
                    id: Self.followUpPrefix + id,
                    repository: followUp.repository,
                    kind: .pullRequest,
                    number: followUp.number,
                    title: followUp.title,
                    reason: .author,
                    isUnread: true,
                    updatedAt: followUp.until,
                    webURL: followUp.url
                )
                let classification = Classification(
                    split: .needsMe,
                    badge: .followUp,
                    because: "You asked to be reminded if nobody had reviewed or commented by \(followUp.until.formatted(date: .abbreviated, time: .shortened)), and nobody has."
                )
                items.append(InboxItem(thread: thread, classification: classification, isUnread: true, resurfacing: .noActivity))
            }
        }
        return items
    }

    /// The pull request a reminder row stands for.
    static func pullRequestID(ofReminder threadID: String) -> String? {
        threadID.hasPrefix(followUpPrefix) ? String(threadID.dropFirst(followUpPrefix.count)) : nil
    }

    /// Done on a reminder row ends the reminder; snoozing it moves it.
    func settleReminders(_ items: [InboxItem], until: Date? = nil) {
        var previous: [String: FollowUp?] = [:]
        for item in items {
            guard let id = Self.pullRequestID(ofReminder: item.id), let followUp = state.followUps[id] else { continue }
            previous[id] = followUp
            if let until {
                state.followUps[id]?.until = until
            } else {
                state.followUps[id] = nil
            }
        }
        guard !previous.isEmpty else { return }
        undoStack.append(.followUps(previous))
        settingsVersion += 1
    }

    /// The glyph for a reminder row: the inbox's own fragment, from My PRs.
    func reminderLenses(_ threadID: String) -> SubjectStore.Lenses? {
        guard let id = Self.pullRequestID(ofReminder: threadID), let node = node(id) else { return nil }
        return SubjectStore.Lenses(pullRequestIcon: node.myPullRequestRow.pullRequestIcon)
    }
}
