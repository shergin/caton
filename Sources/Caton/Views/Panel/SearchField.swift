import CatonCore
import SwiftUI

/// The search, under the section bar while the user searches or a search
/// is in force. It takes the keyboard as it appears; Esc clears it.
struct SearchField: View {
    let model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        let panel = Bindable(model.panel)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search, or repo: author: is: ci:", text: panel.searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($isFocused)
                .onSubmit { model.panel.isSearching = false }
                .onKeyPress(.tab) {
                    model.panel.isSearching = false
                    return .handled
                }
                .onExitCommand {
                    model.panel.searchQuery = ""
                    model.panel.isSearching = false
                }
            if !model.panel.searchQuery.isEmpty, case .split = model.panel.section {
                Button("Save as split") { model.beginSavingSearch() }
                    .buttonStyle(.link)
                    .font(Theme.Font.detail)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Theme.Fill.control, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .padding(.horizontal, Theme.Spacing.margin)
        .padding(.bottom, 8)
        .onAppear { isFocused = model.panel.isSearching }
        .onChange(of: model.panel.isSearching) { _, searching in isFocused = searching }
    }
}
