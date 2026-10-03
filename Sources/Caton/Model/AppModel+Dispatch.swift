import CatonCore
import Foundation

/// Sending queued actions to GitHub, one at a time and paced.
extension AppModel {
    func startDispatching() {
        dispatchTask?.cancel()
        dispatchTask = Task {
            while !Task.isCancelled {
                if let action = state.queue.takeDue(now: .now) {
                    await execute(action)
                    // GitHub asks for a second between mutations sent in bulk.
                    try? await Task.sleep(for: action.verb == .markRead ? .milliseconds(250) : .seconds(1))
                } else {
                    let wait = state.queue.nextDueDate.map { max(0.1, $0.timeIntervalSinceNow) } ?? 1
                    try? await Task.sleep(for: .seconds(min(wait, 1)))
                }
            }
        }
    }

    func wakeDispatcher() {
        if dispatchTask == nil, rest != nil { startDispatching() }
    }

    private func execute(_ action: QueuedAction) async {
        guard let rest else { return }
        // A review request without a notification has no thread to change.
        let hasThread = !action.threadID.hasPrefix(SubjectStore.reviewRequestPrefix)
        do {
            if !dryRun, hasThread {
                switch action.verb {
                case .markRead:
                    try await rest.markRead(threadID: action.threadID)
                case .done:
                    try await rest.markDone(threadID: action.threadID)
                case .unsubscribe:
                    try await rest.unsubscribe(threadID: action.threadID)
                    try await rest.markDone(threadID: action.threadID)
                case .ignore:
                    try await rest.ignore(threadID: action.threadID)
                    try await rest.markDone(threadID: action.threadID)
                }
            }
            state.queue.complete(action.id)
            switch action.verb {
            case .markRead: break
            case .done: state.dismissals[action.threadID] = Dismissal(cause: action.rule.map { .rule($0) } ?? .done, activity: action.activity, at: .now)
            case .unsubscribe: state.dismissals[action.threadID] = Dismissal(cause: .unsubscribe, activity: action.activity, at: .now)
            case .ignore: state.dismissals[action.threadID] = Dismissal(cause: .ignore, activity: action.activity, at: .now)
            }
            save()
        } catch GitHubError.unauthorized {
            _ = state.queue.fail(action.id, retryable: true, now: .now)
            errorMessage = "GitHub rejected the token. Sign in again."
        } catch {
            let retryable = (error as? GitHubError)?.isRetryable ?? true
            if let dropped = state.queue.fail(action.id, retryable: retryable, now: .now) {
                state.readMarks[dropped.threadID] = nil
                let reference = threads[dropped.threadID]?.reference ?? "a thread"
                errorMessage = "Couldn't \(dropped.verb.failureTitle) \(reference): \(error.localizedDescription)"
                recompute()
            }
        }
    }
}

extension Verb {
    var failureTitle: String {
        switch self {
        case .markRead: "mark read"
        case .done: "mark done"
        case .unsubscribe: "unsubscribe from"
        case .ignore: "ignore"
        }
    }
}
