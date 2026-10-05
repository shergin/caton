import CatonCore
import SwiftUI

/// A Feed bundle: one bot's threads, or a busy repository's, as one row
/// that opens in place.
struct BundleRow: View {
    let bundle: ThreadBundle
    let isExpanded: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onDone: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.title)
                    .font(.system(size: 13, weight: bundle.unreadCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isHovered {
                RowButton(symbol: "checkmark", help: "Done for all \(bundle.items.count) (e)", action: onDone)
            } else {
                Age(date: bundle.newest, emphasized: false)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3) : isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bundle.title), \(summary)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var icon: String {
        switch bundle.kind {
        case .bot: "gearshape.2"
        case .repository: "folder"
        }
    }

    private var summary: String {
        let count = bundle.items.count
        var parts = ["\(count) threads"]
        if case .bot = bundle.kind {
            let repositories = Set(bundle.items.map(\.thread.repository.fullName)).count
            if repositories > 1 { parts[0] += " in \(repositories) repositories" }
        }
        if bundle.unreadCount > 0 { parts.append("\(bundle.unreadCount) unread") }
        return parts.joined(separator: " · ")
    }
}
