import CatonCore
import Foundation

/// What survives a relaunch besides Baton's image: the feed's threads, local
/// state with its action queue, and which activity each subject was fetched
/// for. One JSON document, written shortly after each change.
struct PersistedState: Codable {
    var viewer: Viewer?
    var threads: [NotificationThread] = []
    var state = LocalState()
    var fetchedActivity: [String: Date] = [:]
}

@MainActor
final class StatePersistence {
    private let url: URL
    private var pending: Task<Void, Never>?

    init(url: URL = AppPaths.support.appending(path: "state.json")) {
        self.url = url
    }

    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return PersistedState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    /// Writes after a short pause, so a burst of changes is one write.
    func save(_ make: @escaping @MainActor () -> PersistedState) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write(make())
        }
    }

    func saveNow(_ value: PersistedState) {
        pending?.cancel()
        write(value)
    }

    func remove() {
        pending?.cancel()
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ value: PersistedState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
