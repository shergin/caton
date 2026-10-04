import CatonCore
import Foundation

/// What survives a relaunch besides Baton's image: the feed's threads, local
/// state with its action queue, and which activity each subject was fetched
/// for. One JSON document per account, written shortly after each change.
struct PersistedState: Codable {
    var viewer: Viewer?
    var threads: [NotificationThread] = []
    var state = LocalState()
    var fetchedActivity: [String: Date] = [:]
}

@MainActor
final class StatePersistence {
    private let directory: URL
    /// The current account's document; before one is chosen, the document
    /// of versions with a single account.
    private(set) var url: URL
    private var pending: Task<Void, Never>?

    init(directory: URL = AppPaths.support) {
        self.directory = directory
        url = directory.appending(path: "state.json")
    }

    /// Switches to an account's document, writing out what is pending first.
    func use(account key: String) {
        let next = directory.appending(path: "state-\(AppPaths.fileName(key)).json")
        guard next != url else { return }
        if let pending {
            pending.cancel()
            self.pending = nil
        }
        url = next
    }

    /// Whether the single-account document of earlier versions exists.
    var legacyURL: URL { directory.appending(path: "state.json") }

    /// Moves the single-account document to an account's name.
    func adoptLegacy(as key: String) {
        let target = directory.appending(path: "state-\(AppPaths.fileName(key)).json")
        guard FileManager.default.fileExists(atPath: legacyURL.path), !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.moveItem(at: legacyURL, to: target)
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
        let url = url
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, url == self.url else { return }
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
