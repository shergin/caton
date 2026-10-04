import Foundation
import Security

/// Where tokens live, one per account (`github.com/octocat`): the Keychain
/// in release builds; private files in debug builds, whose ad-hoc signature
/// changes on every build and would make the Keychain ask again each time.
enum TokenStore {
    private static let service = "dev.caton.Caton"
    /// The single account of versions before multiple accounts.
    private static let legacyAccount = "github"

    /// A token from the environment, for development: it stands in for the
    /// active account's.
    static var environmentToken: String? {
        ProcessInfo.processInfo.environment["CATON_GITHUB_TOKEN"]?.nonEmpty
    }

    static func load(account key: String) -> String? { read(key) }

    static func save(_ token: String, account key: String) throws { try write(token, key) }

    static func delete(account key: String) { remove(key) }

    /// The token saved before accounts had names, for migrating it.
    static func loadLegacy() -> String? { read(legacyAccount) }

    static func deleteLegacy() { remove(legacyAccount) }

    private static func read(_ account: String) -> String? {
        #if DEBUG
        if let token = (try? String(contentsOf: debugFile(account), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return token
        }
        // A token from before debug builds had their own folder moves over once.
        let shared = AppPaths.sharedSupport.appending(path: debugFile(account).lastPathComponent)
        guard let token = (try? String(contentsOf: shared, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return nil }
        try? write(token, account)
        try? FileManager.default.removeItem(at: shared)
        return token
        #else
        var result: AnyObject?
        let status = SecItemCopyMatching(query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    private static func write(_ token: String, _ account: String) throws {
        #if DEBUG
        let file = debugFile(account)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #else
        SecItemDelete(query(account) as CFDictionary)
        let status = SecItemAdd(query(account).merging([kSecValueData as String: Data(token.utf8)]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        #endif
    }

    private static func remove(_ account: String) {
        #if DEBUG
        try? FileManager.default.removeItem(at: debugFile(account))
        #else
        SecItemDelete(query(account) as CFDictionary)
        #endif
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func debugFile(_ account: String) -> URL {
        account == legacyAccount
            ? AppPaths.support.appending(path: ".debug-token")
            : AppPaths.support.appending(path: ".debug-token-\(AppPaths.fileName(account))")
    }
}

/// Where Caton keeps its files. Debug builds keep their own: a dry run's
/// local marks must never reach the installed app, which would trust them,
/// and two processes must not share Baton's image.
enum AppPaths {
    #if DEBUG
    private static let folder = "Caton Debug"
    private static let cacheFolder = "dev.caton.Caton.debug"
    #else
    private static let folder = "Caton"
    private static let cacheFolder = "dev.caton.Caton"
    #endif

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: folder, directoryHint: .isDirectory)
    }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: cacheFolder, directoryHint: .isDirectory)
    }

    #if DEBUG
    /// Where debug builds kept their files before they had their own folder.
    static var sharedSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Caton", directoryHint: .isDirectory)
    }
    #endif

    /// An account key as a file name: `github.com/octocat` → `github.com-octocat`.
    static func fileName(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
