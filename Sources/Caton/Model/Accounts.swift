import AppKit
import Baton
import CatonCore
import Observation

/// Signing in, the signed-in accounts, and the session of the one that
/// shows. One account shows at a time; each keeps its own token, saved inbox
/// and subject image, and switching hands its session over whole.
@MainActor
@Observable
final class Accounts {
    enum State: Equatable {
        case signedOut
        case connecting
        case signedIn(Viewer)
    }

    enum DeviceSignIn: Equatable {
        case idle
        case waiting(userCode: String, url: URL)
    }

    private(set) var state: State = .signedOut
    private(set) var signInError: String?
    private(set) var deviceSignIn: DeviceSignIn = .idle
    /// The sign-in screen is up for another account; the others stay signed in.
    private(set) var isAdding = false
    /// The active account's session.
    private(set) var session: Session?

    /// Called whenever the active session changes, with the new one.
    @ObservationIgnored var onSession: ((Session?) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let persistence: StatePersistence
    @ObservationIgnored private let dryRun: Bool
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    init(preferences: Preferences, persistence: StatePersistence, dryRun: Bool) {
        self.preferences = preferences
        self.persistence = persistence
        self.dryRun = dryRun
    }

    /// The active account's key, `github.com/octocat`.
    var activeKey: String? {
        if case .signedIn(let viewer) = state { return viewer.key }
        return nil
    }

    var all: [Viewer] { preferences.accounts }

    // MARK: Launch

    func start() {
        adoptSingleAccount()
        if let key = preferences.activeAccount ?? preferences.accounts.first?.key {
            open(account: key)
        } else if let token = TokenStore.environmentToken {
            connect(token: token, host: .dotCom, expected: nil, persisted: PersistedState())
        }
    }

    /// Gives the token and inbox of a version with a single account to that
    /// account by name.
    private func adoptSingleAccount() {
        guard preferences.accounts.isEmpty, FileManager.default.fileExists(atPath: persistence.legacyURL.path) else { return }
        guard let viewer = persistence.load().viewer else { return }
        if let token = TokenStore.loadLegacy() {
            try? TokenStore.save(token, account: viewer.key)
            TokenStore.deleteLegacy()
        }
        persistence.adoptLegacy(as: viewer.key)
        preferences.accounts = [viewer]
        preferences.activeAccount = viewer.key
    }

    /// Loads an account's saved inbox, shows it at once, and connects.
    private func open(account key: String) {
        persistence.use(account: key)
        let persisted = persistence.load()
        let record = preferences.accounts.first { $0.key == key } ?? persisted.viewer
        guard let token = TokenStore.environmentToken ?? TokenStore.load(account: key) else {
            signInError = "Sign in to \(key) again."
            state = .signedOut
            return
        }
        connect(token: token, host: record?.host ?? .dotCom, expected: record, persisted: persisted)
    }

    // MARK: Switching

    /// Shows another signed-in account's inbox. The current one's queued
    /// changes get a moment to reach GitHub, and its inbox is saved.
    func switchTo(_ key: String) async {
        guard key != activeKey, preferences.accounts.contains(where: { $0.key == key }) else { return }
        await setAside()
        preferences.activeAccount = key
        open(account: key)
    }

    /// The account after the active one, if there are several.
    var nextKey: String? {
        let keys = preferences.accounts.map(\.key)
        guard keys.count > 1 else { return nil }
        let index = activeKey.flatMap { keys.firstIndex(of: $0) } ?? -1
        return keys[(index + 1) % keys.count]
    }

    /// Shows the sign-in screen for another account, keeping this one.
    func add() async {
        await setAside()
        isAdding = true
        state = .signedOut
    }

    /// Goes back to the account that was showing before "Add account".
    func cancelAdding() {
        cancelSignIn()
        isAdding = false
        if let key = preferences.activeAccount { open(account: key) }
    }

    /// Puts the current session away: its changes get a moment to reach
    /// GitHub, its inbox is saved, and its work stops.
    private func setAside() async {
        cancelSignIn()
        await session?.drain()
        await session?.end()
        replace(with: nil)
    }

    private func replace(with session: Session?) {
        self.session?.stop()
        self.session = session
        session?.start()
        onSession?(session)
    }

    // MARK: Sign-in

    func signIn(token: String, host: GitHubHost = .dotCom) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        connect(token: token, host: host, expected: nil, persisted: nil)
    }

    func signInWithGitHubCLI(host: GitHubHost = .dotCom) {
        signInError = nil
        signInTask = Task {
            do {
                signIn(token: try await GitHubCLI.token(host: host), host: host)
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    func signInWithDeviceFlow() {
        guard let clientID = DeviceFlow.clientID else {
            signInError = "Device sign-in needs an OAuth App client id (CatonGitHubClientID)."
            return
        }
        signInError = nil
        let flow = DeviceFlow(clientID: clientID, access: preferences.access)
        signInTask = Task {
            do {
                let code = try await flow.requestCode()
                deviceSignIn = .waiting(userCode: code.userCode, url: code.verificationURL)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURL)
                let token = try await flow.waitForToken(code)
                deviceSignIn = .idle
                signIn(token: token)
            } catch is CancellationError {
                deviceSignIn = .idle
            } catch {
                deviceSignIn = .idle
                signInError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        deviceSignIn = .idle
    }

    /// Signs the active account out: its token, its saved inbox and its
    /// cached subjects go. Another signed-in account, if any, takes its place.
    func signOut(because reason: String? = nil) {
        cancelSignIn()
        let key = activeKey ?? preferences.activeAccount
        let previous = session
        replace(with: nil)
        state = .connecting
        let earlierCleanup = cleanupTask
        cleanupTask = Task {
            await earlierCleanup?.value
            await previous?.end()
            previous?.connection?.image?.removeAll()
            if let key {
                persistence.use(account: key)
                preferences.accounts.removeAll { $0.key == key }
            }
            persistence.remove()
            // The environment has ended and its image is gone before the
            // credential is forgotten or another account opens that file.
            if let key { TokenStore.delete(account: key) }
            state = .signedOut
            isAdding = false
            signInError = reason
            if let next = preferences.accounts.first {
                preferences.activeAccount = next.key
                open(account: next.key)
            } else {
                preferences.activeAccount = nil
            }
        }
    }

    /// Signs in with a token. At launch, with the account known from last
    /// time, the cached inbox renders at once and the token is checked behind
    /// it; a new sign-in (no saved inbox handed in) waits for the check.
    private func connect(token: String, host: GitHubHost, expected: Viewer?, persisted: PersistedState?) {
        signInTask?.cancel()
        signInError = nil
        let isNew = persisted == nil
        let cleanup = cleanupTask
        signInTask = Task {
            await cleanup?.value
            guard !Task.isCancelled else { return }
            if let expected, let persisted {
                await activate(token: token, viewer: expected, persisted: persisted)
            } else {
                state = .connecting
            }
            guard !Task.isCancelled else { return }
            do {
                let viewer = try await GitHubREST(token: token, host: host).viewer()
                try Task.checkCancellation()
                if isNew { try TokenStore.save(token, account: viewer.key) }
                if case .signedIn(let current) = state, current.key == viewer.key {
                    remember(viewer)
                    return
                }
                // A new sign-in, or a token that turned out to be another
                // account's: show that account's own saved inbox, if any.
                persistence.use(account: viewer.key)
                await activate(token: token, viewer: viewer, persisted: persistence.load())
            } catch GitHubError.unauthorized {
                guard !Task.isCancelled else { return }
                if isNew {
                    signInError = GitHubError.unauthorized.localizedDescription
                    state = .signedOut
                } else {
                    signOut(because: "GitHub rejected the saved token. Sign in again.")
                }
            } catch {
                guard !Task.isCancelled else { return }
                if isNew {
                    signInError = error.localizedDescription
                    state = .signedOut
                } else {
                    // Offline at launch: the cache stays up and polling keeps trying.
                    session?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Records a signed-in account and makes it the active one.
    private func remember(_ viewer: Viewer) {
        if let index = preferences.accounts.firstIndex(where: { $0.key == viewer.key }) {
            if preferences.accounts[index] != viewer { preferences.accounts[index] = viewer }
        } else {
            preferences.accounts.append(viewer)
        }
        if preferences.activeAccount != viewer.key { preferences.activeAccount = viewer.key }
    }

    /// Makes the account's session: its REST client and Baton environment
    /// sharing one rate governor, its subject image, and its saved inbox.
    private func activate(token: String, viewer: Viewer, persisted: PersistedState) async {
        await session?.end()
        guard !Task.isCancelled else { return }
        persistence.use(account: viewer.key)
        remember(viewer)
        isAdding = false
        let governor = RateGovernor()
        let file = viewer.host.isDotCom ? "subjects-\(viewer.login).sqlite" : "subjects-\(AppPaths.fileName(viewer.key)).sqlite"
        // Another schema starts the image again; a changed fragment does not
        // need to: the check misses only the new fields, and they are fetched.
        let image = Persistence(url: AppPaths.caches.appending(path: file), version: Types.schemaDigest)
        let graph = Baton.Environment(transport: GraphTransport(token: token, host: viewer.host, governor: governor), store: Store(persistence: image, releaseBufferSize: 50))
        graph.log = GraphDiagnostics.record
        let subjects = SubjectStore(environment: graph, viewerID: viewer.nodeID, fetchedActivity: persisted.fetchedActivity)
        let connection = Session.Connection(rest: GitHubREST(token: token, host: viewer.host, governor: governor), graph: graph, subjects: subjects, image: image)
        use(Session(
            viewer: viewer,
            source: .github(connection),
            persisted: persisted,
            persistence: persistence,
            dryRun: dryRun,
            syncsRuleClears: { [preferences] in preferences.syncRuleClears }
        ))
    }

    /// Shows a session as the signed-in account's. Tests hand in a session
    /// over a canned transport or connected to nothing.
    func use(_ session: Session) {
        state = .signedIn(session.viewer)
        session.onUnauthorized = { [weak self] in self?.signOut(because: "GitHub rejected the token. Sign in again.") }
        replace(with: session)
    }
}
