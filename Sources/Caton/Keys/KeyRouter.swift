import CatonCore
import Foundation

/// What an overlay did with a key.
enum KeyOutcome {
    /// The overlay took it.
    case handled
    /// The overlay's text field takes it.
    case typing
    /// The overlay let it through: the list takes the key as if the overlay
    /// had not been there.
    case passed
}

/// Routes the panel's keys. The overlay on top takes them first, each with
/// its own handler beside its view; then a pending `g` and the command table
/// (`Command.all`) decide, by the kind of row selected.
@MainActor
enum KeyRouter {
    /// Handles a key; false lets it through to the window.
    static func handle(_ key: KeyPress, model: AppModel, close: () -> Void) -> Bool {
        switch overlay(key, model: model) {
        case .handled: return true
        case .typing: return false
        case .passed: break
        }

        let panel = model.panel
        let afterG = panel.pendingG
        panel.pendingG = false
        if !afterG, key.characters == "g", key.modifiers.isEmpty, key.special == nil {
            panel.pendingG = true
            return true
        }

        let (command, isBound) = Command.match(key, afterG: afterG, in: model)
        // A key bound to commands that do not apply here does nothing, and
        // neither does a `g` sequence that means nothing.
        guard let command else { return isBound || afterG }
        // Navigation repeats while held; verbs fire once per press.
        if key.isRepeat && !command.repeats { return true }
        if command.run(model) { close() }
        return true
    }

    private static func overlay(_ key: KeyPress, model: AppModel) -> KeyOutcome {
        switch model.panel.overlay {
        case .none: .passed
        case .snooze: SnoozePicker.handle(key, model: model)
        case .zero: ZeroPicker.handle(key, model: model)
        case .peek: PeekView.handle(key, model: model)
        case .help: KeymapOverlay.handle(key, model: model)
        case .why: WhyCard.handle(key, model: model)
        case .commands: CommandMenu.handle(key, model: model)
        case .saveSearch: SaveSearchPrompt.handle(key, model: model)
        case .welcome: WelcomeView.handle(key, model: model)
        case .tips: TipsCard.handle(key, model: model)
        }
    }
}

/// The snooze choices, each on a digit.
struct SnoozeOption: Identifiable, Sendable {
    let key: String
    let title: String
    let date: @Sendable () -> Date
    var id: String { key }

    static let all: [SnoozeOption] = [
        SnoozeOption(key: "1", title: "In 1 hour") { .now.addingTimeInterval(3600) },
        SnoozeOption(key: "2", title: "In 3 hours") { .now.addingTimeInterval(3 * 3600) },
        SnoozeOption(key: "3", title: "Tomorrow 9:00") { nextMorning(after: .now, weekday: nil) },
        SnoozeOption(key: "4", title: "Monday 9:00") { nextMorning(after: .now, weekday: 2) },
        SnoozeOption(key: "5", title: "In a week") { nextMorning(after: .now.addingTimeInterval(6 * 24 * 3600), weekday: nil) },
    ]

    static func nextMorning(after date: Date, weekday: Int?) -> Date {
        let calendar = Calendar.current
        var components = DateComponents(hour: 9, minute: 0)
        components.weekday = weekday
        return calendar.nextDate(after: calendar.startOfDay(for: date).addingTimeInterval(24 * 3600 - 1), matching: components, matchingPolicy: .nextTime) ?? date.addingTimeInterval(24 * 3600)
    }
}
