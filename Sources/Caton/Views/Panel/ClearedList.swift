import CatonCore
import SwiftUI

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
                        ClearedRow(entry: entry, onRestore: { model.restore(entry) }, onOpen: { model.openURL(entry.webURL) })
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct ClearedRow: View {
    let entry: ClearedEntry
    let onRestore: () -> Void
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.reference).font(Theme.Font.detail).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.title).font(Theme.Font.title).lineLimit(1)
            }
            .padding(.leading, Theme.Spacing.margin - Theme.Spacing.rowInset)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.rule?.title ?? "Bulk").font(Theme.Font.caption).foregroundStyle(.secondary)
                Text(Age.short(Date.now.timeIntervalSince(entry.at))).font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
            Button("Restore", action: onRestore)
                .buttonStyle(.borderless)
                .font(Theme.Font.detail)
        }
        .rowChrome(isSelected: false, isHovered: isHovered, height: 42)
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .help("Open \(entry.reference) on GitHub")
    }
}
