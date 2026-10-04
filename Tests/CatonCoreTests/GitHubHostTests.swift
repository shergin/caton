import Foundation
import Testing
@testable import CatonCore

struct GitHubHostTests {
    @Test func each_kind_of_host_has_its_endpoints() {
        #expect(GitHubHost.dotCom.restURL.absoluteString == "https://api.github.com")
        #expect(GitHubHost.dotCom.graphQLURL.absoluteString == "https://api.github.com/graphql")
        let server = GitHubHost("github.acme.com")!
        #expect(server.restURL.absoluteString == "https://github.acme.com/api/v3")
        #expect(server.graphQLURL.absoluteString == "https://github.acme.com/api/graphql")
        let residency = GitHubHost("acme.ghe.com")!
        #expect(residency.restURL.absoluteString == "https://api.acme.ghe.com")
        #expect(residency.graphQLURL.absoluteString == "https://api.acme.ghe.com/graphql")
    }

    @Test func a_typed_host_is_read_from_a_url_or_a_name() {
        #expect(GitHubHost("https://GitHub.Acme.com/settings")?.name == "github.acme.com")
        #expect(GitHubHost("api.github.com")?.isDotCom == true)
        #expect(GitHubHost("not a host") == nil)
        #expect(GitHubHost("") == nil)
    }

    @Test func an_enterprise_thread_links_to_its_own_host() throws {
        let data = Data("[\(notificationJSON(id: "1"))]".utf8)
        let thread = try #require(NotificationDecoding.threads(from: data, host: GitHubHost("github.acme.com")!).first)
        #expect(thread.webURL.absoluteString == "https://github.acme.com/acme/web/pull/42")
    }

    @Test func an_account_saved_before_enterprise_support_is_github_com() throws {
        let json = #"{"login":"octocat","nodeID":"U_1","scopes":["repo"]}"#
        let viewer = try JSONDecoder().decode(Viewer.self, from: Data(json.utf8))
        #expect(viewer.host == .dotCom)
        #expect(viewer.key == "github.com/octocat")
    }

    @Test func the_viewer_comes_from_the_enterprise_api() async throws {
        let client = StubHTTPClient([.init(status: 200, body: #"{"login":"mona","node_id":"U_2"}"#, headers: ["X-OAuth-Scopes": "notifications, repo"])])
        let host = GitHubHost("github.acme.com")!
        let viewer = try await GitHubREST(token: "t", host: host, client: client).viewer()
        #expect(viewer.key == "github.acme.com/mona")
        #expect(client.recorded.first?.url?.absoluteString == "https://github.acme.com/api/v3/user")
    }
}
