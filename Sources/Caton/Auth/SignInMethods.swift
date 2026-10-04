import Foundation

/// Reuses the GitHub CLI's sign-in: `gh auth token` prints an OAuth App token
/// whose `repo` scope reads notifications.
enum GitHubCLI {
    private static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    static var executable: URL? {
        candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func token() async throws -> String {
        guard let executable else { throw SignInError.cliMissing }
        return try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else { throw SignInError.cliSignedOut }
            return token
        }.value
    }
}

/// GitHub's OAuth device flow for an OAuth App: no client secret, no server.
/// The client id is Caton's own OAuth App's; the bundle (`CatonGitHubClientID`)
/// or the environment (`CATON_GITHUB_CLIENT_ID`) can name another.
struct DeviceFlow {
    struct Code: Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let interval: TimeInterval
        let expiresAt: Date
    }

    /// Full reads private repositories' pull requests and checks; Lite asks
    /// only for public ones, and private subjects show no state.
    enum Access: String, CaseIterable, Sendable {
        case full
        case lite

        var scopes: String {
            switch self {
            case .full: "notifications repo"
            case .lite: "notifications public_repo"
            }
        }

        var title: String {
            switch self {
            case .full: "Full"
            case .lite: "Lite"
            }
        }

        var explanation: String {
            switch self {
            case .full: "Reads state and checks in private repositories too. Asks for the repo scope."
            case .lite: "Public repositories only: private pull requests show no state or checks."
            }
        }

        /// The access a token's scopes give.
        init(scopes: Set<String>) {
            self = scopes.contains("repo") || scopes.isEmpty ? .full : .lite
        }
    }

    /// Caton's OAuth App. A client id is public by design; device flow
    /// needs no secret.
    static let defaultClientID = "Ov23liz9s5AlvZVZWZ2k"

    static var clientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "CatonGitHubClientID") as? String)?.nonEmpty
            ?? ProcessInfo.processInfo.environment["CATON_GITHUB_CLIENT_ID"]?.nonEmpty
            ?? defaultClientID
    }

    let clientID: String
    var access: Access = .full
    var session: URLSession = .shared

    func requestCode() async throws -> Code {
        struct Response: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let interval: Int
            let expires_in: Int
        }
        let response: Response = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": access.scopes])
        return Code(
            deviceCode: response.device_code,
            userCode: response.user_code,
            verificationURL: URL(string: response.verification_uri) ?? URL(string: "https://github.com/login/device")!,
            interval: TimeInterval(response.interval),
            expiresAt: .now.addingTimeInterval(TimeInterval(response.expires_in))
        )
    }

    /// Polls until the user approves, declines or the code expires.
    func waitForToken(_ code: Code) async throws -> String {
        struct Response: Decodable {
            let access_token: String?
            let error: String?
            let interval: Int?
        }
        var interval = max(code.interval, 5)
        while Date.now < code.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            let response: Response = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = response.access_token { return token }
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval = TimeInterval(response.interval ?? Int(interval) + 5)
            case "access_denied": throw SignInError.denied
            default: throw SignInError.deviceFlow(response.error ?? "unknown")
            }
        }
        throw SignInError.expired
    }

    private func post<Response: Decodable>(_ url: String, _ form: [String: String]) async throws -> Response {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

enum SignInError: Error, LocalizedError {
    case cliMissing
    case cliSignedOut
    case denied
    case expired
    case deviceFlow(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing: "The GitHub CLI (gh) is not installed."
        case .cliSignedOut: "The GitHub CLI is not signed in. Run `gh auth login` first."
        case .denied: "The sign-in was declined on GitHub."
        case .expired: "The sign-in code expired. Try again."
        case .deviceFlow(let error): "GitHub sign-in failed: \(error)."
        }
    }
}
