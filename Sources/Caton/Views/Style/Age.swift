import SwiftUI

/// How long ago, in a word: `now`, `15m`, `2h`, `3d`. On Needs me, time
/// waiting is spelled out and, after a day, colored.
struct Age: View {
    let date: Date
    let emphasized: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let seconds = context.date.timeIntervalSince(date)
            Text(emphasized && seconds > 4 * 3600 ? "waiting \(Self.short(seconds))" : Self.short(seconds))
                .font(Theme.Font.detail)
                .foregroundStyle(emphasized && seconds > 24 * 3600 ? .orange : .secondary)
                .fixedSize()
        }
    }

    static func short(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "now"
        case ..<3600: "\(Int(seconds / 60))m"
        case ..<86400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86400))d"
        }
    }
}
