import Baton
import CatonCore
import Foundation

/// Writes to the viewer's own pull requests, through Baton mutations
/// declared in `PullRequestWrites.graphql`: a nudge (ask reviewers again)
/// and ready for review.
///
/// Like every verb, a write waits out the undo window first, because a
/// nudge notifies people and cannot be taken back once sent. Then Baton
/// shows the optimistic response at once ("waiting on @alex · 0m", the draft
/// leaving Drafts), GitHub's answer replaces it, and a refusal takes it back.
extension AppModel {
    /// A write waiting for its undo window, by pull request node id.
    struct PendingWrite {
        enum Kind: Equatable {
            case nudge(Nudge)
            case readyForReview
        }

        let kind: Kind
        let reference: String
        let task: Task<Void, Never>

        /// What the row says while it waits.
        var note: String {
            switch kind {
            case .nudge: "asking again…"
            case .readyForReview: "marking ready…"
            }
        }
    }

    /// The pull request a write applies to: the selection in My PRs, or the
    /// pull request behind a reminder row.
    private func writeTarget(_ id: String?) -> String? {
        let id = id ?? selectedID
        if section == .myPullRequests { return id }
        return id.flatMap(Self.pullRequestID(ofReminder:))
    }

    func pendingWriteNote(for pullRequestID: String) -> String? {
        pendingWrites[pullRequestID]?.note
    }

    /// Asks the pull request's reviewers again: those still pending, and
    /// those who asked for changes or only commented. From a reminder row,
    /// the reminder is done: this was what it was for.
    func nudge(_ id: String? = nil) {
        guard let pullRequestID = writeTarget(id) else {
            toast("Nudge works on your pull requests: My PRs (g p) or a Follow up")
            return
        }
        guard let node = myPullRequestNode(pullRequestID) else {
            toast("Open My PRs once so Caton knows who reviews it")
            return
        }
        let status = MyPullRequests.status(node.pullRequestStanding)
        guard !status.isDraft else {
            toast("It is a draft: mark it ready for review first (⇧R)")
            return
        }
        let nudge = status.nudge(excluding: viewerLogin)
        guard !nudge.isEmpty else {
            toast("Nobody to ask again: request a reviewer on GitHub")
            return
        }
        let reminders = targets(id).filter { Self.pullRequestID(ofReminder: $0.id) == pullRequestID }
        if !reminders.isEmpty { settleReminders(reminders) }
        schedule(.nudge(nudge), on: pullRequestID, reference: reference(of: node))
        toast("Asking \(nudge.summary) again · z to undo")
        recompute()
    }

    /// Takes a draft out of draft.
    func markReadyForReview(_ id: String? = nil) {
        guard let pullRequestID = writeTarget(id), let node = myPullRequestNode(pullRequestID) else { return }
        guard MyPullRequests.status(node.pullRequestStanding).isDraft else {
            toast("Already ready for review")
            return
        }
        schedule(.readyForReview, on: pullRequestID, reference: reference(of: node))
        toast("Marking \(reference(of: node)) ready for review · z to undo")
    }

    /// Holds a write for the undo window, then sends it. In a dry run or the
    /// practice inbox, says what it would have done instead.
    private func schedule(_ kind: PendingWrite.Kind, on pullRequestID: String, reference: String) {
        if dryRun || isPractice {
            switch kind {
            case .nudge(let nudge): toast("Dry run: would ask \(nudge.summary) again on \(reference)")
            case .readyForReview: toast("Dry run: would mark \(reference) ready for review")
            }
            return
        }
        pendingWrites[pullRequestID]?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: self?.writeGrace ?? .seconds(Self.grace))
            guard !Task.isCancelled, let self else { return }
            pendingWrites[pullRequestID] = nil
            await send(kind, to: pullRequestID, reference: reference)
        }
        pendingWrites[pullRequestID] = PendingWrite(kind: kind, reference: reference, task: task)
        undoStack.append(.pullRequestWrite(pullRequestID))
    }

    /// Cancels a write still in its undo window.
    func cancelWrite(_ pullRequestID: String) -> Bool {
        guard let pending = pendingWrites.removeValue(forKey: pullRequestID) else { return false }
        pending.task.cancel()
        toast(pending.kind == .readyForReview ? "Still a draft" : "Nudge cancelled")
        return true
    }

    private func send(_ kind: PendingWrite.Kind, to pullRequestID: String, reference: String) async {
        guard let graph else { return }
        let now = Date.now.formatted(.iso8601)
        do {
            switch kind {
            case .nudge(let nudge):
                let input = Variable.object([
                    "pullRequestId": .string(pullRequestID),
                    "userIds": .list(nudge.userIDs.map(Variable.string)),
                    "teamIds": .list(nudge.teamIDs.map(Variable.string)),
                    "botIds": .list(nudge.botIDs.map(Variable.string)),
                    "union": .bool(true),
                ])
                // Before GitHub answers, all the app knows is that review was
                // asked for now.
                let optimistic = NudgeReviewersMutation.OptimisticResponse(requestReviews: .init(pullRequest: .init(
                    id: pullRequestID,
                    timelineItems: .init(nodes: [.init(__typename: "ReviewRequestedEvent", id: "optimistic:\(UUID().uuidString)", createdAt: now)])
                )))
                _ = try await graph.mutate(NudgeReviewersMutation(input: input), optimistic: optimistic.variable)
                toast("Asked \(nudge.summary) again on \(reference)")
            case .readyForReview:
                let optimistic = ReadyForReviewMutation.OptimisticResponse(markPullRequestReadyForReview: .init(pullRequest: .init(id: pullRequestID, isDraft: false)))
                _ = try await graph.mutate(
                    ReadyForReviewMutation(input: .object(["pullRequestId": .string(pullRequestID)])),
                    optimistic: optimistic.variable
                )
                toast("\(reference) is ready for review")
            }
        } catch GitHubError.rateLimited(let until) {
            noteCooldown(until)
            errorMessage = "GitHub's rate limit stopped the change to \(reference); nothing was sent."
        } catch {
            // Baton has already taken the optimistic response back.
            errorMessage = "Couldn't change \(reference): \(error.localizedDescription)"
        }
    }

    private func reference(of node: MyPullRequests.Node) -> String {
        "\(node.myPullRequestRow.repository.nameWithOwner)#\(node.myPullRequestRow.number)"
    }
}
