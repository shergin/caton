import Baton
import CatonCore
import Foundation

/// GitHub's GraphQL endpoint as a Baton transport, sharing the account's rate
/// governor with the REST client so one cooldown pauses both.
struct GraphTransport: Transport {
    let token: String
    let governor: RateGovernor
    let session: URLSession

    init(token: String, governor: RateGovernor, session: URLSession = .shared) {
        self.token = token
        self.governor = governor
        self.session = session
    }

    func execute(_ request: Request) async throws -> Data {
        try await governor.check()
        var urlRequest = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        let headers = Dictionary(
            http.allHeaderFields.compactMap { key, value in (key as? String).map { ($0.lowercased(), "\(value)") } },
            uniquingKeysWith: { first, _ in first }
        )
        await governor.observe(status: http.statusCode, headers: headers, body: data)
        if http.statusCode == 401 { throw GitHubError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
