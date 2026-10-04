import Foundation

/// The app's identity. `scripts/bundle.sh` reads the version from here, so
/// this is the one place it is set.
enum AppInfo {
    static let version = "0.2.1"
    static let repository = URL(string: "https://github.com/shergin/caton")!

    /// The bundle's version when bundled, else this source's.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? version
    }
}
