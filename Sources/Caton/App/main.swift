import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// A menu bar agent: no Dock icon, no app switcher entry.
application.setActivationPolicy(.accessory)
application.run()
