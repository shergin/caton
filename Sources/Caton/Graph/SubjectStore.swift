import Baton
import CatonCore
import Foundation
import Observation

/// The live state of every pull request and issue in the inbox, held in
/// Baton's store. Each subject has a handle the store retains while its thread
/// is in the inbox; the first fetch goes through the handle's own query, and
/// later refreshes go through `nodes(ids:)` in batches into the same records.
@MainActor
@Observable
final class SubjectStore {
    @MainActor
    private enum Handle {
        case pullRequest(OperationHandle<PullRequestSubjectQuery>)
        case issue(OperationHandle<IssueSubjectQuery>)

        var isReady: Bool {
            switch self {
            case .pullRequest(let handle): if case .ready = handle.phase { true } else { false }
            case .issue(let handle): if case .ready = handle.phase { true } else { false }
            }
        }

        func refetch() async throws {
            switch self {
            case .pullRequest(let handle): try await handle.refetch()
            case .issue(let handle): try await handle.refetch()
            }
        }
    }

    private struct Job {
        let threadID: String
        let activity: Date
    }

    /// The fragments a row renders, from whichever operation loaded the subject.
    struct Lenses {
        var pullRequestIcon: PullRequestIcon_pullRequest?
        var pullRequestSignals: PullRequestSignals_pullRequest?
        var issueIcon: IssueIcon_issue?
        var issueSignals: IssueSignals_issue?
    }

    typealias ReviewRequest = ReviewRequestsQuery.Data.Search.Nodes.AsPullRequest

    static let reviewRequestInterval: TimeInterval = 5 * 60
    static let concurrency = 4
    static let batchSize = 50
    static let refreshInterval: TimeInterval = 10 * 60
    static let failureBackoff: TimeInterval = 10 * 60

    let environment: Baton.Environment
    private let viewerID: String
    private var handles: [String: Handle] = [:]
    @ObservationIgnored private var retentions: [String: Retention] = [:]
    @ObservationIgnored private var searchRetentions: [Retention] = []
    @ObservationIgnored private var stopped = false
    /// The thread activity each subject was last fetched for.
    private(set) var fetchedActivity: [String: Date]
    private var failedAt: [String: Date] = [:]
    private var discovery: [Job] = []
    private var queued: Set<String> = []
    private var inFlight = 0
    private var lastRefresh = Date.distantPast
    private let reviewRequests: OperationHandle<ReviewRequestsQuery>
    private var lastReviewRequestSearch = Date.distantPast
    private var reviewRequestsByNodeID: [String: ReviewRequest] {
        guard case .ready(let data) = reviewRequests.phase else { return [:] }
        return Dictionary((data.search.nodes ?? .empty).compactMap { node in
            node.asPullRequest.map { ($0.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
    /// Open pull requests that request the viewer, in a thread's shape with
    /// the pull request's node id as `id`.
    var reviewRequestThreads: [NotificationThread] {
        reviewRequestsByNodeID.values.compactMap { pullRequest in
            guard let url = pullRequest.url else { return nil }
            return NotificationThread(
                id: pullRequest.id,
                repository: RepositoryName(owner: pullRequest.repository.owner.login, name: pullRequest.repository.name),
                kind: .pullRequest,
                number: pullRequest.number,
                title: pullRequest.title,
                reason: .reviewRequested,
                isUnread: true,
                updatedAt: pullRequest.updatedAt ?? .distantPast,
                webURL: url
            )
        }.sorted { $0.id < $1.id }
    }
    /// The viewer's open pull requests. This is the operation the My PRs view
    /// declares, asked for by value: the environment hands the view and this
    /// store the same handle, so the view renders what is kept fresh here.
    let myPullRequests: OperationHandle<MyPullRequestsQuery>

    init(environment: Baton.Environment, viewerID: String, fetchedActivity: [String: Date]) {
        self.environment = environment
        self.viewerID = viewerID
        self.fetchedActivity = fetchedActivity
        reviewRequests = environment.handle(for: ReviewRequestsQuery(), fetchPolicy: .storeOnly)
        searchRetentions.append(reviewRequests.retain())
        // From the image at launch when an earlier one fetched it; fetched now otherwise.
        myPullRequests = environment.handle(for: MyPullRequestsQuery(), fetchPolicy: .storeOrNetwork)
        searchRetentions.append(myPullRequests.retain())
        #if DEBUG
        if ProcessInfo.processInfo.environment["CATON_DUMP"] == "1" {
            let ready = if case .ready = myPullRequests.phase { true } else { false }
            FileHandle.standardError.write(Data("[caton] my pull requests at launch: \(ready ? "ready from the image" : "not in the store")\n".utf8))
        }
        #endif
    }

    /// Runs the searches outside the feed, at most every few minutes; forced,
    /// at most once a minute: open pull requests that request the viewer by
    /// name, and the viewer's own open pull requests.
    func searchReviewRequests(force: Bool = false, now: Date = .now) {
        guard !stopped else { return }
        let age = now.timeIntervalSince(lastReviewRequestSearch)
        guard age > (force ? 60 : Self.reviewRequestInterval) else { return }
        lastReviewRequestSearch = now
        Task {
            // A failed search keeps what the store had; the next one tries again.
            async let requests: Void? = try? reviewRequests.refetch()
            async let mine: Void = refreshMyPullRequests(force: force)
            _ = await (requests, mine)
        }
    }

    private func refreshMyPullRequests(force: Bool) async {
        // The first attach or panel revalidation may already be fetching.
        // A refetch supersedes that request, so share it while it is in flight.
        if case .inFlight = myPullRequests.fetch { return }
        guard force || myPullRequests.isStale || myPullRequests.fetch.failure != nil else { return }
        try? await myPullRequests.refetch()
    }

    /// Reading these values inside Observations follows every operation
    /// that changes them, including a peek, a page, or an optimistic write.
    struct ProjectionInput {
        let facts: [SubjectFacts]
        let reviewRequests: [NotificationThread]
        let standings: [PullRequestStatus]
        let hasMorePullRequests: Bool
    }

    var projectionInput: ProjectionInput {
        var facts = handles.keys.compactMap { self.facts(forThread: $0) }
        facts += reviewRequestsByNodeID.values.map { $0.pullRequestFacts.facts(viewerID: viewerID) }
        var standings: [PullRequestStatus] = []
        var hasMore = false
        if case .ready(let data) = myPullRequests.phase {
            let user = data.viewer.myPullRequestList
            standings = user.pullRequests.nodes.filter { !$0.repository.isArchived }.map { MyPullRequests.status($0.pullRequestStanding) }
            hasMore = user.pullRequests.hasNext
        }
        return ProjectionInput(facts: facts, reviewRequests: reviewRequestThreads, standings: standings, hasMorePullRequests: hasMore)
    }

    /// Brings handles in line with the inbox's threads and starts what is due:
    /// a first fetch for subjects the store lacks, a batched refresh for
    /// subjects with newer activity, and a periodic refresh of open subjects.
    func sync(_ threads: [NotificationThread], now: Date = .now) {
        guard !stopped else { return }
        let enrichable = threads.filter { $0.kind.isIssueOrPullRequest && $0.number != nil }
        let live = Set(enrichable.map(\.id))
        for id in handles.keys where !live.contains(id) {
            retentions[id] = nil
            handles[id] = nil
            fetchedActivity[id] = nil
            failedAt[id] = nil
        }

        var stale: [NotificationThread] = []
        for thread in enrichable.sorted(by: { Self.priority($0) < Self.priority($1) }) {
            let handle = handles[thread.id] ?? makeHandle(thread)
            if let failed = failedAt[thread.id], now.timeIntervalSince(failed) < Self.failureBackoff { continue }
            let current = fetchedActivity[thread.id].map { thread.updatedAt <= $0 } ?? false
            if !handle.isReady {
                enqueueDiscovery(thread)
            } else if !current {
                stale.append(thread)
            }
        }

        if now.timeIntervalSince(lastRefresh) > Self.refreshInterval {
            lastRefresh = now
            let open = enrichable.filter { thread in
                guard let facts = facts(forThread: thread.id) else { return false }
                return facts.state == .open && !stale.contains(where: { $0.id == thread.id })
            }
            stale += open
        }
        if !stale.isEmpty { refresh(stale) }
        pump()
    }

    /// The facts classification reads, once the subject is loaded.
    func facts(for id: ItemID) -> SubjectFacts? {
        switch id {
        case .thread(let threadID): facts(forThread: threadID)
        case .reviewRequest(let nodeID): reviewRequestsByNodeID[nodeID]?.pullRequestFacts.facts(viewerID: viewerID)
        case .followUp: nil
        }
    }

    private func facts(forThread threadID: String) -> SubjectFacts? {
        switch handles[threadID] {
        case .pullRequest(let handle):
            guard case .ready(let data) = handle.phase, let pullRequest = data.repository?.pullRequest else { return nil }
            return pullRequest.pullRequestFacts.facts(viewerID: viewerID)
        case .issue(let handle):
            guard case .ready(let data) = handle.phase, let issue = data.repository?.issue else { return nil }
            return issue.issueFacts.facts()
        case nil:
            return nil
        }
    }

    /// What a row renders, once the subject is loaded.
    func lenses(for id: ItemID) -> Lenses {
        switch id {
        case .thread(let threadID):
            return lenses(forThread: threadID)
        case .reviewRequest(let nodeID):
            guard let reviewRequest = reviewRequestsByNodeID[nodeID] else { return Lenses() }
            return Lenses(pullRequestIcon: reviewRequest.pullRequestIcon, pullRequestSignals: reviewRequest.pullRequestSignals)
        case .followUp:
            return Lenses()
        }
    }

    private func lenses(forThread threadID: String) -> Lenses {
        switch handles[threadID] {
        case .pullRequest(let handle):
            guard case .ready(let data) = handle.phase, let pullRequest = data.repository?.pullRequest else { return Lenses() }
            return Lenses(pullRequestIcon: pullRequest.pullRequestIcon, pullRequestSignals: pullRequest.pullRequestSignals)
        case .issue(let handle):
            guard case .ready(let data) = handle.phase, let issue = data.repository?.issue else { return Lenses() }
            return Lenses(issueIcon: issue.issueIcon, issueSignals: issue.issueSignals)
        case nil:
            return Lenses()
        }
    }

    /// Releases every handle, for a sign-out.
    func releaseAll() {
        stopped = true
        searchRetentions.removeAll()
        retentions.removeAll()
        handles.removeAll()
        discovery.removeAll()
        queued.removeAll()
    }

    // MARK: Fetching

    private func makeHandle(_ thread: NotificationThread) -> Handle {
        let number = thread.number ?? 0
        let handle: Handle
        // `storeOnly`: the store answers from memory or the image, and every
        // fetch goes through the queue below, never on attach.
        switch thread.kind {
        case .pullRequest:
            let operation = PullRequestSubjectQuery(owner: thread.repository.owner, name: thread.repository.name, number: number)
            let pullRequest = environment.handle(for: operation, fetchPolicy: .storeOnly)
            retentions[thread.id] = pullRequest.retain()
            handle = .pullRequest(pullRequest)
        default:
            let operation = IssueSubjectQuery(owner: thread.repository.owner, name: thread.repository.name, number: number)
            let issue = environment.handle(for: operation, fetchPolicy: .storeOnly)
            retentions[thread.id] = issue.retain()
            handle = .issue(issue)
        }
        handles[thread.id] = handle
        return handle
    }

    private func enqueueDiscovery(_ thread: NotificationThread) {
        guard queued.insert(thread.id).inserted else { return }
        discovery.append(Job(threadID: thread.id, activity: thread.updatedAt))
    }

    private func pump() {
        guard !stopped else { return }
        while inFlight < Self.concurrency, !discovery.isEmpty {
            let job = discovery.removeFirst()
            guard let handle = handles[job.threadID] else {
                queued.remove(job.threadID)
                continue
            }
            inFlight += 1
            Task {
                // A refetch that fails throws, even when earlier data keeps the
                // handle ready: only a fetch that landed covers the activity.
                let landed = (try? await handle.refetch()) != nil
                inFlight -= 1
                queued.remove(job.threadID)
                defer { pump() }
                guard !stopped, handles[job.threadID] != nil else { return }
                if landed {
                    fetchedActivity[job.threadID] = job.activity
                    failedAt[job.threadID] = nil
                } else {
                    failedAt[job.threadID] = .now
                }
            }
        }
    }

    /// Refreshes loaded subjects through `nodes(ids:)`, a batch per request.
    private func refresh(_ threads: [NotificationThread]) {
        var pullRequests: [(String, NotificationThread)] = []
        var issues: [(String, NotificationThread)] = []
        for thread in threads {
            guard let nodeID = facts(forThread: thread.id)?.nodeID else { continue }
            if thread.kind == .pullRequest { pullRequests.append((nodeID, thread)) } else { issues.append((nodeID, thread)) }
        }
        for chunk in pullRequests.chunked(Self.batchSize) {
            run(chunk) { try await self.environment.fetch(PullRequestRefreshQuery(ids: chunk.map(\.0))) }
        }
        for chunk in issues.chunked(Self.batchSize) {
            run(chunk) { try await self.environment.fetch(IssueRefreshQuery(ids: chunk.map(\.0))) }
        }
    }

    private func run(_ chunk: [(String, NotificationThread)], _ fetch: @escaping @MainActor () async throws -> Void) {
        inFlight += 1
        Task {
            defer {
                inFlight -= 1
                pump()
            }
            do {
                try await fetch()
                guard !stopped else { return }
                for (_, thread) in chunk { fetchedActivity[thread.id] = thread.updatedAt }
            } catch {
                guard !stopped else { return }
                for (_, thread) in chunk { failedAt[thread.id] = .now }
            }
        }
    }

    /// Threads likelier to need the viewer are enriched first.
    private static func priority(_ thread: NotificationThread) -> Int {
        switch thread.reason {
        case .reviewRequested, .mention, .assign, .author: 0
        case .teamMention, .comment, .manual, .stateChange: 1
        default: 2
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
