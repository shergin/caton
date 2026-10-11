import SwiftUI

/// The logo at a size in points.
struct LogoImage: View {
    let size: CGFloat

    var body: some View {
        if let logo = Assets.logo {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
