import Foundation

/// The HTTP seam, so the REST client is testable without a network.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        return (data, http)
    }
}

public enum GitHubError: Error, Equatable, Sendable, LocalizedError {
    case unauthorized
    case forbidden(String)
    case rateLimited(until: Date)
    case http(status: Int, message: String)
    case missingScopes([String])
    case untrustedURL
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub rejected the token."
        case .forbidden(let message): "GitHub refused the request: \(message)"
        case .rateLimited(let until): "GitHub rate limit; resuming at \(until.formatted(date: .omitted, time: .shortened))."
        case .http(let status, let message): "GitHub answered \(status): \(message)"
        case .missingScopes(let scopes): "The token is missing scopes: \(scopes.joined(separator: ", "))."
        case .untrustedURL: "GitHub returned a link to another host."
        case .invalidResponse: "GitHub returned something unreadable."
        }
    }

    /// Whether trying again later could succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .invalidResponse: true
        case .http(let status, _): status >= 500
        default: false
        }
    }
}

/// One gate for every request of an account: honors `Retry-After`, an
/// exhausted primary limit and secondary-limit refusals.
public actor RateGovernor {
    public private(set) var blockedUntil: Date?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func check() throws {
        guard let blockedUntil else { return }
        if blockedUntil > now() { throw GitHubError.rateLimited(until: blockedUntil) }
        self.blockedUntil = nil
    }

    /// Reads a response's limit headers; returns the cooldown it imposed, if any.
    @discardableResult
    public func observe(status: Int, headers: [String: String], body: Data) -> Date? {
        let current = now()
        var until: Date?
        if let retryAfter = headers["retry-after"].flatMap(TimeInterval.init) {
            until = current.addingTimeInterval(retryAfter)
        } else if headers["x-ratelimit-remaining"] == "0", let reset = headers["x-ratelimit-reset"].flatMap(TimeInterval.init) {
            until = Date(timeIntervalSince1970: reset)
        } else if status == 403 || status == 429, String(decoding: body, as: UTF8.self).localizedCaseInsensitiveContains("rate limit") {
            until = current.addingTimeInterval(60)
        }
        if let until, until > (blockedUntil ?? .distantPast) { blockedUntil = until }
        return until
    }
}

/// The signed-in user.
public struct Viewer: Hashable, Codable, Sendable {
    public let login: String
    public let nodeID: String
    public let scopes: Set<String>
    public let host: GitHubHost

    public init(login: String, nodeID: String, scopes: Set<String>, host: GitHubHost = .dotCom) {
        self.login = login
        self.nodeID = nodeID
        self.scopes = scopes
        self.host = host
    }

    /// Names the account among several: `github.com/octocat`.
    public var key: String { "\(host.name)/\(login)" }

    private enum CodingKeys: String, CodingKey {
        case login, nodeID, scopes, host
    }

    /// Accounts saved before Enterprise support are github.com's.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        login = try container.decode(String.self, forKey: .login)
        nodeID = try container.decode(String.self, forKey: .nodeID)
        scopes = try container.decode(Set<String>.self, forKey: .scopes)
        host = try container.decodeIfPresent(GitHubHost.self, forKey: .host) ?? .dotCom
    }
}

/// The result of a conditional poll.
public enum FeedPoll: Equatable, Sendable {
    case notModified
    case changed([NotificationThread])
}

/// GitHub's notifications REST API: the one feed of the inbox (there is no
/// GraphQL equivalent) and the thread verbs. Conditional requests make an
/// unchanged poll free; pages are 50, the documented maximum.
public actor GitHubREST {
    public static let pageSize = 50
    public static let maximumPages = 20

    private let baseURL: URL
    private let host: GitHubHost
    private let token: String
    private let client: any HTTPClient
    private let governor: RateGovernor
    private var unreadLastModified: String?
    private var recentLastModified: String?
    /// Seconds GitHub asks clients to wait between polls.
    public private(set) var pollInterval: TimeInterval = 60

    public init(token: String, host: GitHubHost = .dotCom, client: any HTTPClient = URLSessionHTTPClient(), governor: RateGovernor = RateGovernor()) {
        self.token = token
        self.client = client
        self.governor = governor
        self.host = host
        baseURL = host.restURL
    }

    // MARK: Identity

    /// The token's user, checked for the scopes the inbox needs.
    public func viewer() async throws -> Viewer {
        let (data, response) = try await send(request(path: "user"))
        struct User: Decodable {
            let login: String
            let node_id: String
        }
        let user = try JSONDecoder().decode(User.self, from: data)
        let scopes = Set((response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        // Classic tokens report their scopes; `repo` implies notifications access.
        if response.value(forHTTPHeaderField: "X-OAuth-Scopes") != nil, !scopes.contains("notifications"), !scopes.contains("repo") {
            throw GitHubError.missingScopes(["notifications"])
        }
        return Viewer(login: user.login, nodeID: user.node_id, scopes: scopes, host: host)
    }

    // MARK: Feed

    /// Unread threads, every page, when page one changed since the last poll.
    public func pollUnread(force: Bool = false) async throws -> FeedPoll {
        let first = request(path: "notifications", query: ["all": "false", "per_page": "\(Self.pageSize)"], ifModifiedSince: force ? nil : unreadLastModified)
        guard let (threads, lastModified) = try await fetchFeed(first) else { return .notModified }
        unreadLastModified = lastModified
        return .changed(threads)
    }

    /// Read and unread threads updated since a date, one page: the
    /// read-but-not-done part of the inbox.
    public func pollRecent(since: Date, force: Bool = false) async throws -> FeedPoll {
        let first = request(
            path: "notifications",
            query: ["all": "true", "per_page": "\(Self.pageSize)", "since": ISO8601DateFormatter().string(from: since)],
            ifModifiedSince: force ? nil : recentLastModified
        )
        guard let (threads, lastModified) = try await fetchFeed(first, maximumPages: 1) else { return .notModified }
        recentLastModified = lastModified
        return .changed(threads)
    }

    private func fetchFeed(_ first: URLRequest, maximumPages: Int = GitHubREST.maximumPages) async throws -> ([NotificationThread], String?)? {
        let (data, response) = try await send(first, allowNotModified: true)
        if response.statusCode == 304 { return nil }
        updatePollInterval(response)
        var threads = try NotificationDecoding.threads(from: data, host: host)
        var next = try nextPageURL(response)
        var pages = 1
        while let url = next, pages < maximumPages {
            var request = URLRequest(url: url)
            authorize(&request)
            let (data, response) = try await send(request)
            threads += try NotificationDecoding.threads(from: data, host: host)
            next = try nextPageURL(response)
            pages += 1
        }
        return (threads, response.value(forHTTPHeaderField: "Last-Modified"))
    }

    // MARK: Verbs

    public func markRead(threadID: String) async throws {
        _ = try await send(request(path: "notifications/threads/\(try Self.safe(threadID))", method: "PATCH"))
    }

    public func markDone(threadID: String) async throws {
        _ = try await send(request(path: "notifications/threads/\(try Self.safe(threadID))", method: "DELETE"))
    }

    /// Unsubscribes the way github.com's Unsubscribe does: mentions and
    /// review requests still notify.
    public func unsubscribe(threadID: String) async throws {
        _ = try await send(request(path: "notifications/threads/\(try Self.safe(threadID))/subscription", method: "DELETE"))
    }

    /// Ignores the thread: nothing on it notifies again.
    public func ignore(threadID: String) async throws {
        var request = request(path: "notifications/threads/\(try Self.safe(threadID))/subscription", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"ignored":true}"#.utf8)
        _ = try await send(request)
    }

    // MARK: Plumbing

    private func request(path: String, method: String = "GET", query: [String: String] = [:], ifModifiedSince: String? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let ifModifiedSince { request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since") }
        authorize(&request)
        return request
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    private func send(_ request: URLRequest, allowNotModified: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await governor.check()
        let (data, response) = try await client.data(for: request)
        let headers = Dictionary(
            response.allHeaderFields.compactMap { key, value in (key as? String).map { ($0.lowercased(), "\(value)") } },
            uniquingKeysWith: { first, _ in first }
        )
        let cooldown = await governor.observe(status: response.statusCode, headers: headers, body: data)
        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 304 where allowNotModified:
            return (data, response)
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            if let cooldown { throw GitHubError.rateLimited(until: cooldown) }
            throw GitHubError.forbidden(Self.message(in: data))
        default:
            throw GitHubError.http(status: response.statusCode, message: Self.message(in: data))
        }
    }

    private func updatePollInterval(_ response: HTTPURLResponse) {
        if let value = response.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init), value > 0 {
            pollInterval = min(value, 3600)
        }
    }

    private func nextPageURL(_ response: HTTPURLResponse) throws -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains(#"rel="next""#) {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end,
                  let url = URL(string: String(part[part.index(after: start)..<end]))
            else { continue }
            guard url.scheme == "https", url.host() == baseURL.host() else { throw GitHubError.untrustedURL }
            return url
        }
        return nil
    }

    private static func message(in data: Data) -> String {
        struct Message: Decodable { let message: String }
        return (try? JSONDecoder().decode(Message.self, from: data).message) ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private static func safe(_ threadID: String) throws -> String {
        guard !threadID.isEmpty, threadID.allSatisfy(\.isNumber) else { throw GitHubError.invalidResponse }
        return threadID
    }
}

/// Decodes the REST notifications payload into threads.
public enum NotificationDecoding {
    struct Payload: Decodable {
        struct Subject: Decodable {
            let title: String
            let url: String?
            let type: String
        }

        struct Repository: Decodable {
            struct Owner: Decodable { let login: String }
            let name: String
            let owner: Owner
            let html_url: String
        }

        let id: String
        let unread: Bool
        let reason: Reason
        let updated_at: Date
        let last_read_at: Date?
        let subject: Subject
        let repository: Repository
    }

    public static func threads(from data: Data, host: GitHubHost = .dotCom) throws -> [NotificationThread] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payloads: [Payload]
        do {
            payloads = try decoder.decode([Payload].self, from: data)
        } catch {
            throw GitHubError.invalidResponse
        }
        return payloads.map { thread($0, host: host) }
    }

    static func thread(_ payload: Payload, host: GitHubHost) -> NotificationThread {
        let repository = RepositoryName(owner: payload.repository.owner.login, name: payload.repository.name)
        let kind = SubjectKind(restType: payload.subject.type)
        let number = kind.isIssueOrPullRequest ? payload.subject.url.flatMap { Int(URL(string: $0)?.lastPathComponent ?? "") } : nil
        return NotificationThread(
            id: payload.id,
            repository: repository,
            kind: kind,
            number: number,
            title: payload.subject.title,
            reason: payload.reason,
            isUnread: payload.unread,
            updatedAt: payload.updated_at,
            lastReadAt: payload.last_read_at,
            webURL: webURL(kind: kind, repository: repository, number: number, host: host)
        )
    }

    /// The subject's page, built on the account's own web host rather than
    /// taken from the payload, so a thread never links elsewhere.
    static func webURL(kind: SubjectKind, repository: RepositoryName, number: Int?, host: GitHubHost) -> URL {
        let base = host.webURL.appending(path: repository.owner).appending(path: repository.name)
        switch (kind, number) {
        case (.pullRequest, let number?): return base.appending(path: "pull/\(number)")
        case (.issue, let number?): return base.appending(path: "issues/\(number)")
        case (.release, _): return base.appending(path: "releases")
        case (.discussion, _): return base.appending(path: "discussions")
        case (.securityAlert, _): return base.appending(path: "security")
        case (.invitation, _): return base.appending(path: "invitations")
        case (.checkSuite, _), (.workflowRun, _): return base.appending(path: "actions")
        default: return base
        }
    }
}
