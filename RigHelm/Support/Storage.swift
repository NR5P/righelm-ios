import Foundation
import Security

/// A RigHelm station the app has connected to (or been told about).
struct SavedServer: Codable, Identifiable, Hashable {
    var name: String
    var host: String
    var port: UInt16
    var id: String { "\(host):\(port)" }
}

enum SavedServers {
    private static let key = "savedServers"

    static func load() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
    }

    static func save(_ servers: [SavedServer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: key)
    }
}

/// Station passwords, kept in the Keychain by "host:port".
enum Keychain {
    private static let service = "RigHelm station password"

    static func password(for account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// A value shared with the audio thread.
final class Locked<T> {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    var get: T { lock.withLock { value } }

    func set(_ v: T) { lock.withLock { value = v } }
}
