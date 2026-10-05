import Foundation

/// What a row of the inbox stands for. Most rows are notification threads;
/// Caton finds or makes the others itself, and only a thread exists on
/// GitHub to mark read, done or unsubscribed.
public enum ItemID: Hashable, Sendable {
    /// A notification thread from the feed, by its REST id.
    case thread(String)
    /// An open pull request that asks the viewer for review but has no
    /// notification thread, by node id (found by search, section 8.3).
    case reviewRequest(String)
    /// A reminder on one of the viewer's pull requests that came due
    /// unanswered, by the pull request's node id.
    case followUp(String)

    /// Whether GitHub has a thread behind the row for verbs to change.
    public var isThread: Bool {
        if case .thread = self { return true }
        return false
    }

    /// The pull request's node id, for a row that stands for one.
    public var pullRequestID: String? {
        switch self {
        case .thread: nil
        case .reviewRequest(let id), .followUp(let id): id
        }
    }

    /// The form local state is saved in, and the one place it is read:
    /// a thread's own id, `review:<node id>` or `followup:<node id>`.
    public var key: String {
        switch self {
        case .thread(let id): id
        case .reviewRequest(let id): "review:" + id
        case .followUp(let id): "followup:" + id
        }
    }

    public init(key: String) {
        if key.hasPrefix("review:") {
            self = .reviewRequest(String(key.dropFirst("review:".count)))
        } else if key.hasPrefix("followup:") {
            self = .followUp(String(key.dropFirst("followup:".count)))
        } else {
            self = .thread(key)
        }
    }
}

extension ItemID: Comparable {
    public static func < (lhs: ItemID, rhs: ItemID) -> Bool { lhs.key < rhs.key }
}

/// Saved as its key, so dictionaries keyed by it keep the format they had
/// when ids were strings.
extension ItemID: Codable, CodingKeyRepresentable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var codingKey: any CodingKey { Key(stringValue: key) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(key: codingKey.stringValue)
    }

    public init(from decoder: any Decoder) throws {
        self.init(key: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}
