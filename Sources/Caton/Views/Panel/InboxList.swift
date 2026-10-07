import CatonCore
import SwiftUI

/// The current section: the laid-out rows of a split, a saved search,
/// Snoozed or Later; My PRs; or Cleared.
struct InboxList: View {
    let model: AppModel
    let close: () -> Void

    @ViewBuilder var body: some View {
        switch model.panel.section {
        case .cleared:
            ClearedList(model: model)
        case .myPullRequests:
            if model.isPractice {
                Text("Your own pull requests show here when you are signed in.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MyPullRequestsView(pullRequests: .init(), model: model)
            }
        default:
            let rows = model.panel.rows
            if rows.isEmpty {
                EmptyState(model: model, filtered: !model.panel.searchQuery.isEmpty || model.panel.unreadOnly)
            } else {
                list(rows)
            }
        }
    }

    private func list(_ rows: [ListRow]) -> some View {
        let waiting = model.panel.section == .split(.needsMe)
        // Threads inside a bot's bundle come from many repositories.
        let acrossRepositories = Set(rows.flatMap { row -> [ItemID] in
            guard case .bundle(let bundle, true) = row, case .bot = bundle.kind else { return [] }
            return bundle.items.map(\.id)
        })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                        case .bundle(let bundle, let isExpanded):
                            BundleRow(
                                bundle: bundle,
                                isExpanded: isExpanded,
                                isSelected: model.panel.selectedID == row.id,
                                onToggle: { model.panel.toggleBundle(bundle.kind) },
                                onDone: { model.done(row.id) }
                            )
                            .id(row.id)
                        case .item(let item, let depth):
                            ThreadRow(
                                item: item,
                                isSelected: model.panel.selectedID == row.id,
                                isChecked: model.panel.checked.contains(item.id),
                                showsWaiting: waiting,
                                showsRepository: !model.panel.groupByRepository || acrossRepositories.contains(item.id),
                                lenses: model.lenses(for: item.id),
                                spokenState: item.spokenState(facts: model.facts(for: item.id)),
                                fallback: model.isPractice ? model.facts(for: item.id) : nil,
                                onOpen: {
                                    model.panel.select(row.id)
                                    if model.open(row.id) { close() }
                                },
                                onToggleCheck: { model.panel.toggleChecked(row.id) },
                                onDone: { model.done(row.id) },
                                onSnooze: { model.beginSnooze(row.id) },
                                onUnsubscribe: { model.unsubscribe(row.id) }
                            )
                            .padding(.leading, depth > 0 ? 14 : 0)
                            .id(row.id)
                        }
                    }
                }
            }
            .onChange(of: model.panel.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }
}

struct EmptyState: View {
    let model: AppModel
    let filtered: Bool

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            if !filtered, model.panel.section == .split(.needsMe) {
                // Caught up: the logo's happy cat.
                LogoImage(size: 48)
            } else {
                Image(systemName: filtered ? "magnifyingglass" : "tray")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
            }
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            if !filtered, case .split = model.panel.section, clearedToday > 0 {
                HStack(spacing: 4) {
                    Text("\(clearedToday) cleared by rules today").foregroundStyle(.tertiary)
                    Button("View") { model.panel.show(.cleared) }.buttonStyle(.link)
                }
                .font(.system(size: 11))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var clearedToday: Int {
        (model.inbox?.state.cleared ?? []).filter { $0.rule != nil && Calendar.current.isDateInToday($0.at) }.count
    }

    private var title: String {
        if filtered { return "No matches" }
        switch model.panel.section {
        case .split(.needsMe): return "Nothing needs you"
        case .split: return "All clear"
        case .saved(let id): return "Nothing matches \(model.inbox?.savedSearch(id)?.query ?? "this search")"
        case .myPullRequests: return "No open pull requests"
        case .snoozed: return "Nothing snoozed"
        case .later: return "Nothing saved for later"
        case .cleared: return "Nothing cleared this week"
        }
    }
}

/// What rules and bulk clears took away this week, newest first, each with
/// its page and a way back.
struct ClearedList: View {
    let model: AppModel

    var body: some View {
        if (model.inbox?.state.cleared ?? []).isEmpty {
            EmptyState(model: model, filtered: false)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach((model.inbox?.state.cleared ?? []).reversed()) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.reference).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                Text(entry.title).font(.system(size: 12)).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(entry.rule?.title ?? "Bulk").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(Age.short(Date.now.timeIntervalSince(entry.at))).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Button("Restore") { model.restore(entry) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .onTapGesture { model.openURL(entry.webURL) }
                        .help("Open \(entry.reference) on GitHub")
                    }
                }
            }
        }
    }
}
