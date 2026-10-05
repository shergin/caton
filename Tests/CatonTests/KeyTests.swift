import CatonCore
import Foundation
import Testing
@testable import Caton

/// Keys through the router and the command table: which verb a key runs on
/// which kind of row, what repeats, the `g` prefix, Esc's layers and the
/// overlays' own keys.
extension AppModelTests {
    /// Presses a key; true when the panel closed.
    @discardableResult
    func press(_ characters: String = "", special: KeyPress.Special? = nil, modifiers: KeyPress.Modifiers = [], isRepeat: Bool = false) -> Bool {
        var closed = false
        _ = KeyRouter.handle(KeyPress(characters, special: special, modifiers: modifiers, isRepeat: isRepeat), model: model, close: { closed = true })
        return closed
    }

    @Test func the_table_never_binds_one_key_to_two_commands_on_the_same_row() {
        let commands = Command.all
        #expect(Set(commands.map(\.id)).count == commands.count)
        for (index, first) in commands.enumerated() {
            for second in commands[(index + 1)...] where first.bindings.contains(where: second.bindings.contains) {
                guard case .rows(let a) = first.scope, case .rows(let b) = second.scope else {
                    Issue.record("\(first.id) and \(second.id) share a key and one applies anywhere")
                    continue
                }
                #expect(a.isDisjoint(with: b), "\(first.id) and \(second.id) share a key and a row kind")
            }
        }
    }

    @Test func a_key_runs_the_verb_for_the_kind_of_row() {
        loadThree()
        #expect(Command.match(KeyPress("h"), afterG: false, in: model).command?.id == "snooze")
        model.panel.selectedID = .pullRequest("PR_7")
        #expect(Command.match(KeyPress("h"), afterG: false, in: model).command?.id == "remind")
        #expect(Command.match(KeyPress(special: .enter), afterG: false, in: model).command?.id == "open-pull-request")
    }

    @Test func nudge_does_nothing_on_a_thread_and_asks_on_a_reminder() {
        loadThree()
        press("n")
        #expect(model.panel.toasts.isEmpty)
        session.state.followUps["PR_7"] = followUp(until: .now.addingTimeInterval(-60))
        session.recompute()
        model.panel.select(row("followup:PR_7"))
        press("n")
        // Nothing has loaded My PRs, so Caton cannot know whom to ask.
        #expect(model.panel.toasts.map(\.message) == ["Open My PRs once so Caton knows who reviews it"])
    }

    @Test func a_held_verb_fires_once_and_navigation_repeats() {
        loadThree()
        press("e", isRepeat: true)
        #expect(session.state.queue.isEmpty)
        press("j", isRepeat: true)
        #expect(model.panel.selectedID == row("2"))
    }

    @Test func g_waits_for_its_second_key() {
        loadThree()
        press("G")
        #expect(model.panel.selectedID == row("3"))
        press("g")
        press("g")
        #expect(model.panel.selectedID == row("1"))
        press("g")
        press("p")
        #expect(model.panel.section == .myPullRequests)
        // A sequence that means nothing ends quietly.
        press("g")
        press("e")
        #expect(session.state.queue.isEmpty)
    }

    @Test func shift_tab_goes_back_a_split() {
        loadThree()
        press(special: .tab)
        #expect(model.panel.section == .split(.team))
        press(special: .tab, modifiers: .shift)
        press(special: .tab, modifiers: .shift)
        #expect(model.panel.section == .split(.feed))
    }

    @Test func escape_clears_the_search_then_the_checks_then_closes() {
        loadThree()
        model.panel.toggleChecked(row("1"))
        model.panel.searchQuery = "Thread"
        #expect(!press(special: .escape))
        #expect(model.panel.searchQuery.isEmpty)
        #expect(!press(special: .escape))
        #expect(model.panel.checked.isEmpty)
        #expect(press(special: .escape))
    }

    @Test func opening_a_thread_closes_the_panel() {
        loadThree()
        #expect(press(special: .enter))
        #expect(opened.urls.map(\.lastPathComponent) == ["1"])
    }

    @Test func the_snooze_picker_takes_its_digits() {
        loadThree()
        press("h")
        #expect(model.panel.overlay == .snooze)
        press("n")
        #expect(model.panel.snoozeOnlyIfQuiet)
        press("1")
        #expect(model.panel.overlay == .none)
        #expect(model.panel.count(.snoozed) == 1)
        // The digit went to the picker, not to the splits.
        #expect(model.panel.section == .split(.needsMe))
    }

    @Test func a_peek_closes_and_lets_the_key_act_on_the_row() {
        loadThree()
        press("p")
        #expect(model.panel.overlay == .peek)
        press(" ")
        #expect(model.panel.overlay == .none)
        #expect(model.panel.selectedID == row("1"))
        press("p")
        press("e")
        #expect(model.panel.overlay == .none)
        #expect(session.state.queue.actions.map(\.verb) == [.done])
    }

    @Test func the_command_menu_offers_what_applies_to_the_selection() {
        loadThree()
        let ids = Command.menu(in: model).map(\.id)
        #expect(ids.contains("snooze"))
        #expect(!ids.contains("remind"))
        #expect(!ids.contains("nudge"))
        #expect(!ids.contains("delete-search"))
    }

    @Test func digits_past_the_splits_reach_saved_searches() {
        loadThree()
        model.panel.searchQuery = "Thread"
        model.saveSearch(named: "Threads")
        model.panel.show(.split(.needsMe))
        press("5")
        #expect(model.panel.isOnSavedSplit)
        #expect(Command.menu(in: model).contains { $0.id == "delete-search" })
    }
}
