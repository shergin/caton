import Foundation

/// Where an account lives: github.com, a GitHub Enterprise Cloud tenant with
/// data residency (`acme.ghe.com`), or a GitHub Enterprise Server host. Each
/// has its own REST and GraphQL endpoints and web host.
public struct GitHubHost: Hashable, Codable, Sendable, CustomStringConvertible {
    public let name: String

    public static let dotCom = GitHubHost(validated: "github.com")

    /// Reads what a user types: a bare host or a URL, any case.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: text), let host = url.host() { text = host }
        text = text.split(separator: "/").first.map(String.init) ?? ""
        if text == "api.github.com" || text == "www.github.com" { text = "github.com" }
        guard !text.isEmpty, text.contains("."), text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { return nil }
        name = text
    }

    private init(validated name: String) {
        self.name = name
    }

    public var description: String { name }
    public var isDotCom: Bool { name == "github.com" }
    /// GitHub Enterprise Cloud with data residency, which keeps github.com's
    /// API shape under an `api.` subdomain.
    public var isDataResidency: Bool { name.hasSuffix(".ghe.com") }

    public var restURL: URL {
        if isDotCom { return URL(string: "https://api.github.com")! }
        if isDataResidency { return URL(string: "https://api.\(name)")! }
        return URL(string: "https://\(name)/api/v3")!
    }

    public var graphQLURL: URL {
        if isDotCom { return URL(string: "https://api.github.com/graphql")! }
        if isDataResidency { return URL(string: "https://api.\(name)/graphql")! }
        return URL(string: "https://\(name)/api/graphql")!
    }

    public var webURL: URL { URL(string: "https://\(name)")! }
}
