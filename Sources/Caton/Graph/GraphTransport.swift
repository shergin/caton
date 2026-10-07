import Baton
import CatonCore
import Foundation

/// GitHub's GraphQL endpoint as a Baton transport, sharing the account's rate
/// governor with the REST client so one cooldown pauses both.
struct GraphTransport: Transport {
    let token: String
    let host: GitHubHost
    let governor: RateGovernor
    let client: any HTTPClient
    let retryDelay: Duration

    init(token: String, host: GitHubHost = .dotCom, governor: RateGovernor, client: any HTTPClient = URLSessionHTTPClient(), retryDelay: Duration = .milliseconds(250)) {
        self.token = token
        self.host = host
        self.governor = governor
        self.client = client
        self.retryDelay = retryDelay
    }

    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        Self.once {
            var attempt = 0
            while true {
                try Task.checkCancellation()
                do {
                    return try await execute(request)
                } catch {
                    // A mutation may already have reached GitHub. Only
                    // queries get two retries for temporary failures.
                    guard request.kind == .query, attempt < 2, Self.isRetryable(error) else { throw error }
                    try await Task.sleep(for: retryDelay * (1 << attempt) * Double.random(in: 0.8...1.2))
                    attempt += 1
                }
            }
        }
    }

    private func execute(_ request: Request) async throws -> Data {
        try await governor.check()
        var urlRequest = URLRequest(url: host.graphQLURL)
        urlRequest.timeoutInterval = 15
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = request.body
        let (data, http) = try await client.data(for: urlRequest)
        let headers = Dictionary(
            http.allHeaderFields.compactMap { key, value in (key as? String).map { ($0.lowercased(), "\(value)") } },
            uniquingKeysWith: { first, _ in first }
        )
        await governor.observe(status: http.statusCode, headers: headers, body: data)
        if http.statusCode == 401 { throw GitHubError.unauthorized }
        if http.statusCode == 403 || http.statusCode == 429 { try await governor.check() }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if let error = error as? TransportError { return (500..<600).contains(error.statusCode) }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
