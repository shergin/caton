import SwiftUI

/// The chrome of a layer over the list: the menu material, the panel's own
/// corner, a hairline edge and a soft shadow. Every overlay wears it, so
/// they look like one family.
struct Card: ViewModifier {
    let width: CGFloat?
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Theme.Fill.hairline))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

extension View {
    func card(width: CGFloat? = nil, padding: CGFloat = 14) -> some View {
        modifier(Card(width: width, padding: padding))
    }
}

/// A choice in a picker card: its key, its title and, on the right, what
/// it amounts to, with a highlight under the pointer.
struct MenuRow<Trailing: View>: View {
    let key: String
    let title: String
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                KeyCap(key: key)
                Text(title).font(Theme.Font.body)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 26)
            .background(isHovered && isEnabled ? Theme.Fill.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
    }
}

extension MenuRow where Trailing == EmptyView {
    init(key: String, title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.init(key: key, title: title, isEnabled: isEnabled, action: action) { EmptyView() }
    }
}

/// The heading of a card.
struct CardTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(Theme.Font.titleEmphasized)
    }
}

/// The line under a card's choices that says what they do.
struct CardNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
