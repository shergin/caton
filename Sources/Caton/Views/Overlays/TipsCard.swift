import CatonCore
import SwiftUI

/// The three keys worth learning first, shown once.
struct TipsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Three keys to start with").font(.system(size: 13, weight: .semibold))
            tip("e", "Done: it leaves until something new happens.")
            tip("h", "Snooze: it comes back later, or sooner if it needs you.")
            tip("⇥", "Next split: Needs me, Team, Following, Feed.")
            Text("⌘K finds everything else. Press any key to start.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 26, height: 22)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
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
