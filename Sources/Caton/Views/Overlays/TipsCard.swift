import CatonCore
import SwiftUI

/// The three keys worth learning first, shown once.
struct TipsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle("Three keys to start with")
            tip("e", "Done: it leaves until something new happens.")
            tip("h", "Snooze: it comes back later, or sooner if it needs you.")
            tip("⇥", "Next split: Needs me, Team, Following, Feed.")
            Text("⌘K finds everything else. Press any key to start.")
                .font(Theme.Font.detail)
                .foregroundStyle(.secondary)
        }
        .card(width: 320, padding: 16)
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            KeyCap(key: key).frame(width: 26, alignment: .center)
            Text(text).font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension TipsCard {
    /// Any key ends the tip, and the keys it teaches also do their job.
    static func handle(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        model.dismissTips()
        return key.special == .escape ? .handled : .passed
    }
}
