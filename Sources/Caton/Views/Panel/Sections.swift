import CatonCore
import SwiftUI

extension Panel.Section {
    /// The views that are not splits, in the order the More menu lists them.
    static let more: [Panel.Section] = [.myPullRequests, .snoozed, .later, .cleared]

    /// The glyph the More menu shows beside a section.
    var symbol: String {
        switch self {
        case .split(.needsMe): "person"
        case .split(.team): "person.2"
        case .split(.following): "eye"
        case .split(.feed): "dot.radiowaves.left.and.right"
        case .saved: "magnifyingglass"
        case .myPullRequests: "arrow.triangle.pull"
        case .snoozed: "moon.zzz"
        case .later: "bookmark"
        case .cleared: "tray"
        }
    }
}

extension AppModel {
    /// A section's name: the split's, the saved search's, or the view's.
    func title(of section: Panel.Section) -> String {
        switch section {
        case .split(let split): split.title
        case .saved(let id): inbox?.savedSearch(id)?.name ?? "Saved search"
        case .myPullRequests: "My pull requests"
        case .snoozed: "Snoozed"
        case .later: "Later"
        case .cleared: "Cleared"
        }
    }
}
