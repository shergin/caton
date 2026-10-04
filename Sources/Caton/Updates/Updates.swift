import AppKit
import CatonCore
import Observation

/// Checks GitHub Releases for a newer Caton, once a day and on request, and
/// says so in the panel's status strip. Caton ships through Homebrew, which
/// does the installing: the app only tells the user to run the upgrade.
@MainActor
@Observable
final class Updates {
    struct Release: Equatable {
        let version: String
        let url: URL
    }

    static let latest = URL(string: "https://api.github.com/repos/shergin/caton/releases/latest")!
    /// What installs an update.
    static let upgradeCommand = "brew upgrade --cask caton"
    static let interval: TimeInterval = 24 * 3600

    private(set) var available: Release?
    private(set) var isChecking = false
    /// The outcome of a check the user asked for, for Settings and the menu.
    private(set) var status: String?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored let currentVersion: String

    init(currentVersion: String = AppInfo.currentVersion, session: URLSession = .shared) {
        self.currentVersion = currentVersion
        self.session = session
    }

    func start() {
        schedule?.cancel()
        schedule = Task {
            while !Task.isCancelled {
                await check(userInitiated: false)
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// Puts the upgrade command on the clipboard.
    func copyUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.upgradeCommand, forType: .string)
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if userInitiated { status = "Checking…" }
        do {
            var request = URLRequest(url: Self.latest)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status != 404 else {
                // No release published yet: nothing is newer.
                available = nil
                if userInitiated { self.status = "Caton \(currentVersion) is the latest version." }
                return
            }
            struct Payload: Decodable {
                let tag_name: String
                let html_url: URL
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            if let latest = Version(payload.tag_name), let current = Version(currentVersion), latest > current,
               payload.html_url.host() == "github.com" {
                available = Release(version: latest.description, url: payload.html_url)
                if userInitiated { self.status = "Caton \(latest) is available." }
            } else {
                available = nil
                if userInitiated { self.status = "Caton \(currentVersion) is the latest version." }
            }
        } catch {
            if userInitiated { status = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }
}
