import Baton
import CatonCore
import Foundation

/// The viewer's own open pull requests, read from the handle the subject
/// store shares with `MyPullRequestsView`; the reminders set on them, which
/// join Needs me when they come due unanswered; and the writes to them,
/// through the Baton mutations in `PullRequestWrites.graphql`.
extension Session {
    // MARK: My PRs

    /// The pull requests in the order the view shows them, for the keyboard.
    var myPullRequestNodes: [MyPullRequests.Node] {
        guard let handle = subjects?.myPullRequests, case .ready(let data) = handle.phase else { return [] }
        return MyPullRequests.groups(data.viewer.myPullRequestList, now: .now).flatMap(\.nodes)
    }

    func myPullRequestNode(_ id: String) -> MyPullRequests.Node? { myPullRequestNodes.first { $0.id == id } }

    /// `owner/name#123`.
    static func reference(of node: MyPullRequests.Node) -> String {
        "\(node.myPullRequestRow.repository.nameWithOwner)#\(node.myPullRequestRow.number)"
    }

    // MARK: Reminders

    func followUp(for id: String) -> FollowUp? { state.followUps[id] }

    /// Reminds about a pull request at `until` unless someone reviews or
    /// comments first. False when the pull request is not loaded.
    @discardableResult
    func remind(_ id: String, until: Date) -> Bool {
        guard let node = myPullRequestNode(id), let url = URL(string: node.url) else { return false }
        let row = node.myPullRequestRow
        let parts = row.repository.nameWithOwner.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return false }
        let previous = state.followUps[id]
        state.followUps[id] = FollowUp(
            until: until,
            answeredAt: MyPullRequests.status(node.pullRequestStanding).lastResponse(excluding: viewer.login),
            repository: RepositoryName(owner: parts[0], name: parts[1]),
            number: row.number,
            title: row.title,
            url: url
        )
        history.append(.followUps([id: previous]))
        recompute()
        return true
    }

    /// Removes a reminder; false when there was none.
    @discardableResult
    func clearReminder(_ id: String) -> Bool {
        guard let previous = state.followUps.removeValue(forKey: id) else { return false }
        history.append(.followUps([id: previous]))
        recompute()
        return true
    }

    /// Done on a reminder row ends the reminder; snoozing it moves it.
    func settleReminders(_ items: [InboxItem], until: Date? = nil) {
        var previous: [String: FollowUp?] = [:]
        for item in items {
            guard case .followUp(let id) = item.id, let followUp = state.followUps[id] else { continue }
            previous[id] = followUp
            if let until {
                state.followUps[id]?.until = until
            } else {
                state.followUps[id] = nil
            }
        }
        guard !previous.isEmpty else { return }
        history.append(.followUps(previous))
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
            let lastResponse = node.flatMap { MyPullRequests.status($0.pullRequestStanding).lastResponse(excluding: viewer.login) }
            switch followUp.outcome(lastResponse: lastResponse, now: now) {
            case .waiting:
                continue
            case .answered:
                state.followUps[id] = nil
            case .due:
                let thread = NotificationThread(
                    id: id,
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
                items.append(InboxItem(id: .followUp(id), thread: thread, classification: classification, isUnread: true, resurfacing: .noActivity))
            }
        }
        return items
    }

    /// The glyph for a reminder row: the inbox's own fragment, from My PRs.
    func reminderLenses(_ item: ItemID) -> SubjectStore.Lenses? {
        guard case .followUp(let id) = item, let node = myPullRequestNode(id) else { return nil }
        return SubjectStore.Lenses(pullRequestIcon: node.myPullRequestRow.pullRequestIcon)
    }

    // MARK: Writes

    /// A write waiting for its undo window.
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

    /// Whom a nudge on a pull request would ask, or why it cannot.
    enum NudgePlan {
        case ask(Nudge, reference: String)
        case isDraft
        case nobody
        case unknown
    }

    func nudgePlan(for pullRequestID: String) -> NudgePlan {
        guard let node = myPullRequestNode(pullRequestID) else { return .unknown }
        let status = MyPullRequests.status(node.pullRequestStanding)
        if status.isDraft { return .isDraft }
        let nudge = status.nudge(excluding: viewer.login)
        return nudge.isEmpty ? .nobody : .ask(nudge, reference: Self.reference(of: node))
    }

    /// Whether a pull request is a draft, if it is loaded.
    func isDraft(_ pullRequestID: String) -> Bool? {
        myPullRequestNode(pullRequestID).map { MyPullRequests.status($0.pullRequestStanding).isDraft }
    }

    func reference(ofPullRequest id: String) -> String? {
        myPullRequestNode(id).map(Self.reference(of:))
    }

    /// Holds a write for the undo window, then sends it. Returns false when
    /// the session sends nothing (a dry run, or connected to nothing).
    func schedule(_ kind: PendingWrite.Kind, on pullRequestID: String, reference: String) -> Bool {
        guard !dryRun, graph != nil else { return false }
        pendingWrites[pullRequestID]?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: self?.writeGrace ?? .seconds(Session.grace))
            guard !Task.isCancelled, let self else { return }
            pendingWrites[pullRequestID] = nil
            await send(kind, to: pullRequestID, reference: reference)
        }
        pendingWrites[pullRequestID] = PendingWrite(kind: kind, reference: reference, task: task)
        history.append(.pullRequestWrite(pullRequestID))
        return true
    }

    /// Cancels a write still in its undo window, and says what it was.
    func cancelWrite(_ pullRequestID: String) -> PendingWrite.Kind? {
        guard let pending = pendingWrites.removeValue(forKey: pullRequestID) else { return nil }
        pending.task.cancel()
        return pending.kind
    }

    /// Sends a write. Baton shows the optimistic response at once, GitHub's
    /// answer replaces it, and a refusal takes it back.
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
                onWrite?("Asked \(nudge.summary) again on \(reference)")
            case .readyForReview:
                let optimistic = ReadyForReviewMutation.OptimisticResponse(markPullRequestReadyForReview: .init(pullRequest: .init(id: pullRequestID, isDraft: false)))
                _ = try await graph.mutate(
                    ReadyForReviewMutation(input: .object(["pullRequestId": .string(pullRequestID)])),
                    optimistic: optimistic.variable
                )
                onWrite?("\(reference) is ready for review")
            }
        } catch GitHubError.rateLimited(let until) {
            noteCooldown(until)
            errorMessage = "GitHub's rate limit stopped the change to \(reference); nothing was sent."
        } catch {
            // Baton has already taken the optimistic response back.
            errorMessage = "Couldn't change \(reference): \(error.localizedDescription)"
        }
    }
}
