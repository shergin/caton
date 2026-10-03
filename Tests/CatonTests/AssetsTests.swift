import AppKit
import Testing
@testable import Caton

@MainActor
struct AssetsTests {
    @Test func every_menu_bar_state_has_a_template_image_at_menu_bar_size() throws {
        for state in [Assets.MenuBar.disabled, .enabled, .active] {
            let image = try #require(Assets.menuBar(state))
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            // The @2x rendition is there for Retina menu bars.
            #expect(image.representations.contains { $0.pixelsWide == 36 })
        }
    }

    @Test func the_logo_and_the_app_icon_load() {
        #expect(Assets.logo != nil)
        #expect(Assets.appIcon != nil)
    }
}
