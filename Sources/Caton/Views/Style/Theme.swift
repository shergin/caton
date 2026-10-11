import SwiftUI

/// The panel's design in one place: type, radii, spacing and fills, named
/// by role. A view says what a thing is; this file says how it looks, so a
/// change to the look is a change here, not a search through the views.
enum Theme {
    enum Font {
        /// A row's title.
        static let title = SwiftUI.Font.system(size: 13)
        /// A row's title while unread, and a card's heading.
        static let titleEmphasized = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// A segment of the section bar.
        static let segment = SwiftUI.Font.system(size: 12, weight: .medium)
        static let segmentSelected = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// The text of a card or a menu row.
        static let body = SwiftUI.Font.system(size: 12)
        /// A row's first line, a hint's label, a badge.
        static let detail = SwiftUI.Font.system(size: 11)
        static let detailEmphasized = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// A footnote under a card's choices.
        static let caption = SwiftUI.Font.system(size: 10)
        /// The header above a group of rows.
        static let sectionHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// A count beside a title: digits that do not shift as they change.
        static let count = SwiftUI.Font.system(size: 11, weight: .medium).monospacedDigit()
        /// The key on a key cap.
        static let key = SwiftUI.Font.system(size: 10, weight: .medium)
    }

    enum Radius {
        /// A row's highlight.
        static let row: CGFloat = 7
        /// A control: a segment, a menu row, the search field.
        static let control: CGFloat = 6
        /// A card over the list, as the panel's own corner.
        static let card: CGFloat = 12
        static let key: CGFloat = 4
    }

    enum Spacing {
        /// The panel's side margin, where the content aligns.
        static let margin: CGFloat = 12
        /// How far a row's highlight sits in from the panel's edge.
        static let rowInset: CGFloat = 6
    }

    enum Fill {
        /// Under the pointer.
        static let hover = Color.primary.opacity(0.06)
        /// Under the selection: the system's selection color, through the glass.
        static let selection = Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
        /// The track of the section bar, the search field.
        static let control = Color.primary.opacity(0.06)
        static let keyCap = Color.primary.opacity(0.07)
        /// A one-point edge around a control or a card.
        static let hairline = Color.primary.opacity(0.09)
    }
}
