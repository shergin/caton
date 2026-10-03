import Baton
import CatonCore
import Foundation

/// The live state of every pull request and issue in the inbox, held in
/// Baton's store. Each subject has a handle the store retains while its thread
/// is in the inbox; the first fetch goes through the handle's own query, and
/// later refreshes go through `nodes(ids:)` in batches into the same records.
@MainActor
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

        func refetch() async {
            switch self {
            case .pullRequest(let handle): await handle.refetch()
            case .issue(let handle): await handle.refetch()
            }
        }

        func release() {
            switch self {
            case .pullRequest(let handle): handle.release()
            case .issue(let handle): handle.release()
            }
        }
    }

    private struct Job {
        let threadID: String
        let activity: Date
    }

    static let concurrency = 4
    static let batchSize = 50
    static let refreshInterval: TimeInterval = 10 * 60
    static let failureBackoff: TimeInterval = 10 * 60

    let environment: Baton.Environment
    private let viewerID: String
    /// Called after a fetch commits, so the inbox can be classified again.
    var onChange: (() -> Void)?

    private var handles: [String: Handle] = [:]
    /// The thread activity each subject was last fetched for.
    private(set) var fetchedActivity: [String: Date]
    private var failedAt: [String: Date] = [:]
    private var discovery: [Job] = []
    private var queued: Set<String> = []
    private var inFlight = 0
    private var lastRefresh = Date.distantPast

    init(environment: Baton.Environment, viewerID: String, fetchedActivity: [String: Date]) {
        self.environment = environment
        self.viewerID = viewerID
        self.fetchedActivity = fetchedActivity
    }

    /// Brings handles in line with the inbox's threads and starts what is due:
    /// a first fetch for subjects the store lacks, a batched refresh for
    /// subjects with newer activity, and a periodic refresh of open subjects.
    func sync(_ threads: [NotificationThread], now: Date = .now) {
        let enrichable = threads.filter { $0.kind.isIssueOrPullRequest && $0.number != nil }
        let live = Set(enrichable.map(\.id))
        for (id, handle) in handles where !live.contains(id) {
            handle.release()
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
                guard let facts = facts(for: thread) else { return false }
                return facts.state == .open && !stale.contains(where: { $0.id == thread.id })
            }
            stale += open
        }
        if !stale.isEmpty { refresh(stale) }
        pump()
    }

    /// The facts classification reads, once the subject is loaded.
    func facts(for thread: NotificationThread) -> SubjectFacts? {
        switch handles[thread.id] {
        case .pullRequest(let handle):
            guard case .ready(let data) = handle.phase, let pullRequest = data.repository?.pullRequest else { return nil }
            return PullRequestFactsReader(pullRequest: pullRequest.pullRequestFacts).facts(viewerID: viewerID)
        case .issue(let handle):
            guard case .ready(let data) = handle.phase, let issue = data.repository?.issue else { return nil }
            return IssueFactsReader(issue: issue.issueFacts).facts()
        case nil:
            return nil
        }
    }

    /// The pull request a row renders, once loaded.
    func pullRequest(for threadID: String) -> PullRequestSubjectQuery.Data.Repository.PullRequest? {
        guard case .pullRequest(let handle) = handles[threadID], case .ready(let data) = handle.phase else { return nil }
        return data.repository?.pullRequest
    }

    /// The issue a row renders, once loaded.
    func issue(for threadID: String) -> IssueSubjectQuery.Data.Repository.Issue? {
        guard case .issue(let handle) = handles[threadID], case .ready(let data) = handle.phase else { return nil }
        return data.repository?.issue
    }

    /// Releases every handle, for a sign-out.
    func releaseAll() {
        for handle in handles.values { handle.release() }
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
            pullRequest.retain()
            handle = .pullRequest(pullRequest)
        default:
            let operation = IssueSubjectQuery(owner: thread.repository.owner, name: thread.repository.name, number: number)
            let issue = environment.handle(for: operation, fetchPolicy: .storeOnly)
            issue.retain()
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
        while inFlight < Self.concurrency, !discovery.isEmpty {
            let job = discovery.removeFirst()
            guard let handle = handles[job.threadID] else {
                queued.remove(job.threadID)
                continue
            }
            inFlight += 1
            Task {
                await handle.refetch()
                inFlight -= 1
                queued.remove(job.threadID)
                if handle.isReady {
                    fetchedActivity[job.threadID] = job.activity
                    failedAt[job.threadID] = nil
                } else {
                    failedAt[job.threadID] = .now
                }
                onChange?()
                pump()
            }
        }
    }

    /// Refreshes loaded subjects through `nodes(ids:)`, a batch per request.
    private func refresh(_ threads: [NotificationThread]) {
        var pullRequests: [(String, NotificationThread)] = []
        var issues: [(String, NotificationThread)] = []
        for thread in threads {
            guard let nodeID = facts(for: thread)?.nodeID else { continue }
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
                for (_, thread) in chunk { fetchedActivity[thread.id] = thread.updatedAt }
                onChange?()
            } catch {
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
