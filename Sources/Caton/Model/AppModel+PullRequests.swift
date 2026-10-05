import AppKit
import CatonCore

/// My PRs' commands: moving through the viewer's pull requests, reminders,
/// and the writes (nudge, ready for review). The data and the writes
/// themselves are the session's (`Session+PullRequests.swift`).
extension AppModel {
    var myPullRequestNodes: [MyPullRequests.Node] { inbox?.myPullRequestNodes ?? [] }

    func myPullRequestNode(_ id: String) -> MyPullRequests.Node? { inbox?.myPullRequestNode(id) }

    func followUp(for id: String) -> FollowUp? { inbox?.followUp(for: id) }

    func pendingWriteNote(for pullRequestID: String) -> String? { inbox?.pendingWrites[pullRequestID]?.note }

    /// The pull request a write applies to: the one named, the selection in
    /// My PRs, or the pull request behind a reminder row.
    private func writeTarget(_ id: String?) -> String? {
        if let id { return id }
        switch panel.selectedID {
        case .pullRequest(let id): return id
        case .item(.followUp(let id)): return id
        default: return nil
        }
    }

    func openPullRequest(_ id: String? = nil) {
        guard let id = id ?? panel.selectedPullRequestID, let url = myPullRequestNode(id).flatMap({ URL(string: $0.url) }) else { return }
        panel.select(.pullRequest(id))
        openURL(url)
    }

    func copyPullRequestLink(_ id: String? = nil) {
        guard let id = id ?? panel.selectedPullRequestID, let node = myPullRequestNode(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url, forType: .string)
        panel.toast("Copied \(Session.reference(of: node))")
    }

    // MARK: Reminders

    /// Opens the picker for a reminder on a pull request.
    func beginReminder(_ id: String? = nil) {
        guard let id = id ?? panel.selectedPullRequestID, myPullRequestNode(id) != nil else { return }
        panel.select(.pullRequest(id))
        panel.snoozeTarget = .pullRequest(id)
        panel.overlay = .snooze
    }

    /// Reminds about a pull request at `until` unless someone reviews or
    /// comments first.
    func remind(_ id: String, until: Date) {
        guard let undo = inbox?.remind(id, until: until) else { return }
        undoStack.append(undo)
        panel.toast("Reminding \(until.formatted(.relative(presentation: .named))) if nobody answers · z to undo")
    }

    func clearReminder(_ id: String) {
        guard let undo = inbox?.clearReminder(id) else { return }
        undoStack.append(undo)
        panel.toast("Reminder removed · z to undo")
    }

    // MARK: Writes

    /// Asks the pull request's reviewers again: those still pending, and
    /// those who asked for changes or only commented. From a reminder row,
    /// the reminder is done: this was what it was for.
    func nudge(_ id: String? = nil) {
        guard let inbox, let pullRequestID = writeTarget(id) else {
            panel.toast("Nudge works on your pull requests: My PRs (g p) or a Follow up")
            return
        }
        switch inbox.nudgePlan(for: pullRequestID) {
        case .unknown:
            panel.toast("Open My PRs once so Caton knows who reviews it")
        case .isDraft:
            panel.toast("It is a draft: mark it ready for review first (⇧R)")
        case .nobody:
            panel.toast("Nobody to ask again: request a reviewer on GitHub")
        case .ask(let nudge, let reference):
            let reminders = panel.targets().filter { $0.id == .followUp(pullRequestID) }
            if let undo = inbox.settleReminders(reminders) { undoStack.append(undo) }
            guard let undo = inbox.schedule(.nudge(nudge), on: pullRequestID, reference: reference) else {
                panel.toast("Dry run: would ask \(nudge.summary) again on \(reference)")
                return
            }
            undoStack.append(undo)
            panel.toast("Asking \(nudge.summary) again · z to undo")
        }
    }

    /// Takes a draft out of draft.
    func markReadyForReview(_ id: String? = nil) {
        guard let inbox, let pullRequestID = writeTarget(id), let reference = inbox.reference(ofPullRequest: pullRequestID) else { return }
        guard inbox.isDraft(pullRequestID) == true else {
            panel.toast("Already ready for review")
            return
        }
        guard let undo = inbox.schedule(.readyForReview, on: pullRequestID, reference: reference) else {
            panel.toast("Dry run: would mark \(reference) ready for review")
            return
        }
        undoStack.append(undo)
        panel.toast("Marking \(reference) ready for review · z to undo")
    }
}
