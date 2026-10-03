import Foundation
import Security

/// Where the token lives: the Keychain in release builds; a private file in
/// debug builds, whose ad-hoc signature changes on every build and would make
/// the Keychain ask again each time.
enum TokenStore {
    private static let service = "dev.caton.Caton"
    private static let account = "github"

    static func load() -> String? {
        if let environment = ProcessInfo.processInfo.environment["CATON_GITHUB_TOKEN"], !environment.isEmpty {
            return environment
        }
        #if DEBUG
        return (try? String(contentsOf: debugFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        #else
        var result: AnyObject?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    static func save(_ token: String) throws {
        #if DEBUG
        try FileManager.default.createDirectory(at: debugFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: debugFile, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: debugFile.path)
        #else
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query.merging([kSecValueData as String: Data(token.utf8)]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        #endif
    }

    static func delete() {
        #if DEBUG
        try? FileManager.default.removeItem(at: debugFile)
        #else
        SecItemDelete(query as CFDictionary)
        #endif
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static var debugFile: URL {
        AppPaths.support.appending(path: ".debug-token")
    }
}

enum AppPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Caton", directoryHint: .isDirectory)
    }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "dev.caton.Caton", directoryHint: .isDirectory)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
