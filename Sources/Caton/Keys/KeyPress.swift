import AppKit

/// A key press as the panel reads it: what was typed, or which special key,
/// with which modifiers. Built from an `NSEvent`, or by hand in tests.
struct KeyPress: Equatable {
    enum Special: Equatable {
        case escape, enter, tab, up, down, left, right, pageUp, pageDown, home, end
    }

    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let control = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let shift = Modifiers(rawValue: 8)
    }

    var characters: String
    var special: Special?
    var modifiers: Modifiers
    /// Held down: navigation repeats, verbs do not.
    var isRepeat: Bool

    init(_ characters: String = "", special: Special? = nil, modifiers: Modifiers = [], isRepeat: Bool = false) {
        self.characters = characters
        self.special = special
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let special: Special? = switch event.keyCode {
        case 53: .escape
        case 36, 76: .enter
        case 48: .tab
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 116: .pageUp
        case 121: .pageDown
        case 115: .home
        case 119: .end
        default: nil
        }
        // With Command or Control, the key's own character names it.
        let characters = modifiers.isDisjoint(with: [.command, .control]) ? event.characters ?? "" : (event.charactersIgnoringModifiers ?? "").lowercased()
        self.init(characters, special: special, modifiers: modifiers, isRepeat: event.isARepeat)
    }

    /// Command, Control or Option: the modifiers that make a key a shortcut
    /// rather than typing. Shift is part of the character.
    var shortcutModifiers: Modifiers { modifiers.intersection([.command, .control, .option]) }
}

/// A key a command answers to.
enum KeyBinding: Equatable {
    /// A character typed with no shortcut modifier (Shift is in the character).
    case character(String)
    /// A special key, with exactly these modifiers: ⇥ and ⇧⇥ differ.
    case special(KeyPress.Special, KeyPress.Modifiers = [])
    /// A character with exactly these modifiers, Command or Control among
    /// them: ⌘Z is not ⌘⇧Z.
    case shortcut(String, KeyPress.Modifiers)
    /// `g` and then a character.
    case afterG(String)

    func matches(_ key: KeyPress, afterG: Bool) -> Bool {
        switch self {
        case .character(let character):
            !afterG && key.special == nil && key.shortcutModifiers.isEmpty && key.characters == character
        case .special(let special, let modifiers):
            !afterG && key.special == special && key.modifiers == modifiers
        case .shortcut(let character, let modifiers):
            !afterG && key.modifiers == modifiers && key.characters == character
        case .afterG(let character):
            afterG && key.shortcutModifiers.isEmpty && key.characters == character
        }
    }

    /// How the keymap writes the binding: `e`, `⏎`, `⌘Z`, `⌃F`, `g p`.
    var label: String {
        switch self {
        case .character(" "): "space"
        case .character(let character) where character.count == 1 && character.uppercased() == character && character.lowercased() != character:
            "⇧" + character
        case .character(let character): character
        case .special(let special, let modifiers): Self.symbols(modifiers) + Self.symbol(special)
        case .shortcut(let character, let modifiers): Self.symbols(modifiers) + character.uppercased()
        case .afterG(let character): "g \(character)"
        }
    }

    private static func symbols(_ modifiers: KeyPress.Modifiers) -> String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
    }

    private static func symbol(_ special: KeyPress.Special) -> String {
        switch special {
        case .escape: "esc"
        case .enter: "⏎"
        case .tab: "⇥"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        case .home: "↖"
        case .end: "↘"
        }
    }
}
