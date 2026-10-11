import SwiftUI

/// A key as the footer and the cards draw it: a small cap, like a key on
/// the keyboard.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(Theme.Font.key)
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(Theme.Fill.keyCap, in: RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous).strokeBorder(Theme.Fill.hairline))
    }
}

/// A key and what it does: `e done`.
struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            KeyCap(key: key)
            Text(label).font(Theme.Font.detail).foregroundStyle(.secondary)
        }
    }
}
