import Baton
import CatonCore
import Foundation
import Testing
@testable import Caton

struct GraphTransportTests {
    actor HTTP: HTTPClient {
        struct Reply: Sendable {
            var status: Int
            var headers: [String: String] = [:]
            var body = Data(#"{"data":{"viewer":{"login":"me"}}}"#.utf8)
            var failure: URLError.Code?
        }

        var replies: [Reply]
        private(set) var requests: [URLRequest] = []

        init(_ replies: [Reply]) { self.replies = replies }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw URLError(.badServerResponse) }
            let reply = replies.removeFirst()
            if let failure = reply.failure { throw URLError(failure) }
            return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
        }
    }

    func request(_ kind: Request.Kind = .query) -> Request {
        Request(operationName: "Example", kind: kind, document: .text("query Example{viewer{login}}"), variables: .none)
    }

    @Test func a_query_retries_temporary_failures_and_uses_batons_wire_encoding() async throws {
        let http = HTTP([.init(status: 503), .init(status: 502), .init(status: 200)])
        let transport = GraphTransport(token: "test-token", governor: RateGovernor(), client: http, retryDelay: .zero)
        let request = request()
        _ = try await transport.payload(request)
        let sent = await http.requests
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.httpBody == request.body })
        #expect(sent[0].url == GitHubHost.dotCom.graphQLURL)
        #expect(sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func retries_stop_after_three_attempts() async {
        let http = HTTP(Array(repeating: .init(status: 503), count: 4))
        let transport = GraphTransport(token: "test", governor: RateGovernor(), client: http, retryDelay: .zero)
        await #expect(throws: TransportError.self) { try await transport.payload(request()) }
        #expect(await http.requests.count == 3)
    }

    @Test func a_mutation_is_never_replayed() async {
        let http = HTTP([.init(status: 503), .init(status: 200)])
        let transport = GraphTransport(token: "test", governor: RateGovernor(), client: http, retryDelay: .zero)
        await #expect(throws: TransportError.self) { try await transport.payload(request(.mutation)) }
        #expect(await http.requests.count == 1)
    }

    @Test func an_expired_token_is_not_retried() async {
        let http = HTTP([.init(status: 401)])
        let transport = GraphTransport(token: "test", governor: RateGovernor(), client: http, retryDelay: .zero)
        await #expect(throws: GitHubError.unauthorized) { try await transport.payload(request()) }
        #expect(await http.requests.count == 1)
    }

    @Test func a_lost_query_connection_is_retried() async throws {
        let http = HTTP([.init(status: 0, failure: .networkConnectionLost), .init(status: 200)])
        let transport = GraphTransport(token: "test", governor: RateGovernor(), client: http, retryDelay: .zero)
        _ = try await transport.payload(request())
        #expect(await http.requests.count == 2)
    }

    @Test func a_cancelled_request_is_not_retried() async {
        let http = HTTP([.init(status: 0, failure: .cancelled)])
        let transport = GraphTransport(token: "test", governor: RateGovernor(), client: http, retryDelay: .zero)
        await #expect(throws: URLError(.cancelled)) { try await transport.payload(request()) }
        #expect(await http.requests.count == 1)
    }

    @Test func a_cooldown_from_graphql_also_blocks_rest() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let governor = RateGovernor(now: { now })
        let http = HTTP([.init(status: 429, headers: ["Retry-After": "30"])])
        let graph = GraphTransport(token: "test", governor: governor, client: http, retryDelay: .zero)
        let rest = GitHubREST(token: "test", client: http, governor: governor)
        let expected = GitHubError.rateLimited(until: now.addingTimeInterval(30))
        await #expect(throws: expected) { try await graph.payload(request()) }
        await #expect(throws: expected) { try await rest.pollUnread() }
        #expect(await http.requests.count == 1)
    }
}
