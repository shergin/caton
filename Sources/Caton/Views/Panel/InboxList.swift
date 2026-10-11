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
                    .font(Theme.Font.body)
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
                            SectionHeader(title)
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
                .padding(.bottom, 6)
            }
            .onChange(of: model.panel.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }
}
