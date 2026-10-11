import SwiftUI

/// What every row of the list shares: its height, the highlight under the
/// selection and under the pointer, inset from the panel's edge the way a
/// menu item's is.
struct RowChrome: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.trailing, 8)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isSelected ? Theme.Fill.selection : isHovered ? Theme.Fill.hover : .clear)
            )
            .padding(.horizontal, Theme.Spacing.rowInset)
            .contentShape(Rectangle())
    }
}

extension View {
    func rowChrome(isSelected: Bool, isHovered: Bool, height: CGFloat = 46) -> some View {
        modifier(RowChrome(isSelected: isSelected, isHovered: isHovered, height: height))
    }
}

/// A verb on a row, shown while the pointer is over it.
struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(isHovered ? Theme.Fill.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// The header above a group of rows: a repository, or whose move it is.
struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Theme.Font.sectionHeader)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.margin)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }
}
