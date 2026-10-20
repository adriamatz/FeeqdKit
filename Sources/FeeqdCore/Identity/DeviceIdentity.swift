import Foundation
import Security

/// The store could not be read right now, which is not the same as it being empty.
package struct SecretStoreUnavailable: Error, Equatable {}

package protocol SecretStore: Sendable {
    /// `nil` only when the value is known to be absent; throws when the store cannot say.
    func read(account: String) throws -> String?
    @discardableResult func write(_ value: String, account: String) -> Bool
}

/// The Keychain, for the one secret-ish value the SDK keeps: the device id.
package struct KeychainStore: SecretStore {
    package let service: String

    package init(service: String = "com.feeqd.feeqdkit") {
        self.service = service
    }

    package func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            // Typically a launch in the background before the first unlock: the id is there
            // but locked. Reading that as "no id" would mint a second one for this device.
            throw SecretStoreUnavailable()
        }
    }

    @discardableResult
    package func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        query[kSecValueData as String] = data
        // After first unlock: an app woken in the background can still read it. This device
        // only: a second device restored from the same backup must not share the id, or the
        // two would overwrite each other's votes.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// For tests and previews.
package final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var locked = false

    package init(_ values: [String: String] = [:]) {
        self.values = values
    }

    /// Stands in for a Keychain that is still locked: reads fail and writes are refused.
    package func setLocked(_ value: Bool) {
        lock.lock()
        locked = value
        lock.unlock()
    }

    package func read(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if locked { throw SecretStoreUnavailable() }
        return values[account]
    }

    @discardableResult
    package func write(_ value: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if locked { return false }
        values[account] = value
        return true
    }
}

/// Who this device is, for anonymous votes and comments.
///
/// The backend does not derive identity from hardware: the SDK generates an opaque KSUID once
/// and sends it on every `/sdk/*` request. If the Keychain comes back empty — a restore to a
/// new phone without iCloud Keychain — a new id is generated and the old votes stay with the
/// old one. That is the accepted cost of never asking for an email.
///
/// A Keychain that cannot be read is a different case: the id is still there, so no new one is
/// made and the request fails instead, to be retried once the device is unlocked.
package actor DeviceIdentity: DeviceIdentityProviding {
    package static let account = "device-id"

    private let store: SecretStore
    private var cached: String?
    /// The id in use is not in the store yet: the write failed, and is tried again on each use
    /// so a later launch does not come back with a different id.
    private var unsaved = false

    package init(store: SecretStore = KeychainStore()) {
        self.store = store
    }

    /// Read once per process: a Keychain access per request would be a Keychain access per scroll.
    package func deviceID() throws -> String {
        if let cached {
            if unsaved { unsaved = !store.write(cached, account: Self.account) }
            return cached
        }
        let id: String
        if let stored = try store.read(account: Self.account), !stored.isEmpty {
            id = stored
        } else {
            id = KSUID.generate()
            unsaved = !store.write(id, account: Self.account)
        }
        cached = id
        return id
    }

    package func reset() {
        let id = KSUID.generate()
        unsaved = !store.write(id, account: Self.account)
        cached = id
    }
}

/// K-Sortable Unique IDentifier: 4 bytes of time plus 16 random, base62, 27 characters.
package enum KSUID {
    private static let epoch: TimeInterval = 1_400_000_000
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    package static let length = 27

    package static func generate(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        let timestamp = UInt32(max(0, now.timeIntervalSince1970 - epoch))
        bytes[0] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[1] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[2] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[3] = UInt8(truncatingIfNeeded: timestamp)
        var generator = SystemRandomNumberGenerator()
        for index in 4..<20 {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return base62(bytes)
    }

    private static func base62(_ input: [UInt8]) -> String {
        var number = input
        var digits: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            var quotient: [UInt8] = []
            for byte in number {
                let value = remainder * 256 + Int(byte)
                let digit = value / 62
                remainder = value % 62
                if !quotient.isEmpty || digit != 0 { quotient.append(UInt8(digit)) }
            }
            digits.append(alphabet[remainder])
            number = quotient
        }
        let encoded = String(digits.reversed())
        return String(repeating: "0", count: max(0, length - encoded.count)) + encoded
    }
}
