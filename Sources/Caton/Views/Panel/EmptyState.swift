import CatonCore
import SwiftUI

/// A section with nothing in it. Needs me at zero gets the logo's happy cat.
struct EmptyState: View {
    let model: AppModel
    let filtered: Bool

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            if !filtered, model.panel.section == .split(.needsMe) {
                LogoImage(size: 56)
            } else {
                Image(systemName: filtered ? "magnifyingglass" : "tray")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text(title).font(Theme.Font.title).foregroundStyle(.secondary)
            if !filtered, case .split = model.panel.section, clearedToday > 0 {
                HStack(spacing: 4) {
                    Text("\(clearedToday) cleared by rules today").foregroundStyle(.tertiary)
                    Button("View") { model.panel.show(.cleared) }.buttonStyle(.link)
                }
                .font(Theme.Font.detail)
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
