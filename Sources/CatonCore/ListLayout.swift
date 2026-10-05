import Foundation

/// Threads that show as one row until opened: everything one bot sent, or a
/// busy repository's threads.
public struct ThreadBundle: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case bot(String)
        case repository(String)
    }

    public let kind: Kind
    /// The threads, in display order.
    public let items: [InboxItem]

    public init(kind: Kind, items: [InboxItem]) {
        self.kind = kind
        self.items = items
    }

    public var title: String {
        switch kind {
        case .bot(let login): login
        case .repository(let name): name
        }
    }

    public var unreadCount: Int { items.filter(\.isUnread).count }

    public var newest: Date { items.map(\.thread.updatedAt).max() ?? .distantPast }
}

/// A row anywhere in the panel, as selection and SwiftUI know it.
public enum RowID: Hashable, Sendable {
    case header(String)
    case item(ItemID)
    case bundle(ThreadBundle.Kind)
    /// One of the viewer's pull requests in My PRs, by node id.
    case pullRequest(String)

    public var isSelectable: Bool {
        if case .header = self { return false }
        return true
    }

    /// The inbox item the row is, if it is one.
    public var item: ItemID? {
        if case .item(let id) = self { return id }
        return nil
    }
}

/// One line of the list: a repository header, a thread, or a bundle.
public enum ListRow: Identifiable, Hashable, Sendable {
    case header(String)
    /// A thread; at depth 1 it is inside an open bundle.
    case item(InboxItem, depth: Int)
    case bundle(ThreadBundle, isExpanded: Bool)

    public var id: RowID {
        switch self {
        case .header(let title): .header(title)
        case .item(let item, _): .item(item.id)
        case .bundle(let bundle, _): .bundle(bundle.kind)
        }
    }

    public var isSelectable: Bool { id.isSelectable }
}

/// Lays a section's threads out as rows. Pure, so what collapses where is
/// testable without a view.
///
/// Feed bundles: a bot that sent at least two threads gets one row, and,
/// grouped by repository, a repository with at least four of the remaining
/// threads gets one row in place of its header, unless it would be the only
/// row. Other sections only group.
public enum ListLayout {
    public static let botMinimum = 2
    public static let repositoryMinimum = 4

    /// - Parameters:
    ///   - items: the threads in display order, grouped by repository when
    ///     `groupByRepository` is on.
    ///   - bundles: whether to collapse bundles (Feed, without a search).
    ///   - expanded: the ids of the bundles the user opened.
    ///   - bot: the login of the bot that authored a thread, if one did.
    public static func rows(
        _ items: [InboxItem],
        groupByRepository: Bool,
        bundles: Bool,
        expanded: Set<ThreadBundle.Kind>,
        bot: (InboxItem) -> String?
    ) -> [ListRow] {
        var rows: [ListRow] = []
        var rest = items

        if bundles {
            var byBot: [String: [InboxItem]] = [:]
            var order: [String] = []
            for item in items {
                guard let login = bot(item) else { continue }
                if byBot[login] == nil { order.append(login) }
                byBot[login, default: []].append(item)
            }
            let botBundles = order
                .compactMap { login in byBot[login].flatMap { $0.count >= botMinimum ? ThreadBundle(kind: .bot(login), items: $0) : nil } }
                .sorted { $0.newest > $1.newest }
            if !botBundles.isEmpty {
                let bundled = Set(botBundles.flatMap { $0.items.map(\.id) })
                rest.removeAll { bundled.contains($0.id) }
                if groupByRepository { rows.append(.header("Bots")) }
                for bundle in botBundles { append(bundle, to: &rows, expanded: expanded) }
            }
        }

        guard groupByRepository else {
            rows += rest.map { .item($0, depth: 0) }
            return rows
        }
        var groups: [[InboxItem]] = []
        for item in rest {
            if let last = groups.last?.last, last.thread.repository == item.thread.repository {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        // One repository and nothing else: a bundle would only hide it.
        let collapses = bundles && (groups.count > 1 || !rows.isEmpty)
        for group in groups {
            let name = group[0].thread.repository.fullName
            if collapses, group.count >= repositoryMinimum {
                append(ThreadBundle(kind: .repository(name), items: group), to: &rows, expanded: expanded)
            } else {
                rows.append(.header(name))
                rows += group.map { .item($0, depth: 0) }
            }
        }
        return rows
    }

    private static func append(_ bundle: ThreadBundle, to rows: inout [ListRow], expanded: Set<ThreadBundle.Kind>) {
        let isExpanded = expanded.contains(bundle.kind)
        rows.append(.bundle(bundle, isExpanded: isExpanded))
        if isExpanded { rows += bundle.items.map { .item($0, depth: 1) } }
    }
}
