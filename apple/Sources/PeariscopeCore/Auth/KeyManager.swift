import Foundation
import CryptoKit
import Security

/// Manages device key pairs and trusted device list.
/// Keys are stored in the macOS/iOS Keychain.
public final class KeyManager: Sendable {
    private static let serviceName = "com.peariscope.keys"
    private static let deviceKeyAccount = "device-keypair"
    private static let trustedDevicesAccount = "trusted-devices"

    public init() {}

    // MARK: - Device Key Pair

    /// Get or create the device's persistent key pair
    public func getOrCreateDeviceKey() throws -> (publicKey: Data, privateKey: Data) {
        if let existing = try? loadFromKeychain(account: Self.deviceKeyAccount) {
            // Stored as privateKey (32 bytes) + publicKey (32 bytes)
            let privateKey = existing.prefix(32)
            let publicKey = existing.suffix(32)
            return (publicKey: Data(publicKey), privateKey: Data(privateKey))
        }

        // Generate new Curve25519 key pair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = Data(privateKey.publicKey.rawRepresentation)
        let privateKeyData = Data(privateKey.rawRepresentation)

        // Store concatenated in Keychain
        let combined = privateKeyData + publicKeyData
        try saveToKeychain(account: Self.deviceKeyAccount, data: combined)

        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }

    /// Get just the public key (for display/sharing)
    public func getPublicKey() throws -> Data {
        let keys = try getOrCreateDeviceKey()
        return keys.publicKey
    }

    /// Public key as a short display string (first 8 bytes hex)
    public func getPublicKeyShort() throws -> String {
        let key = try getPublicKey()
        return key.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Trusted Devices

    public struct TrustedDevice: Codable, Identifiable, Sendable {
        public var id: String { publicKeyHex }
        public let publicKeyHex: String
        public let name: String
        public let addedAt: Date

        public init(publicKeyHex: String, name: String, addedAt: Date = Date()) {
            self.publicKeyHex = publicKeyHex
            self.name = name
            self.addedAt = addedAt
        }
    }

    /// Load trusted devices list
    public func loadTrustedDevices() -> [TrustedDevice] {
        guard let data = try? loadFromKeychain(account: Self.trustedDevicesAccount),
              let devices = try? JSONDecoder().decode([TrustedDevice].self, from: data) else {
            return []
        }
        return devices
    }

    /// Add a device to the trusted list
    public func trustDevice(_ device: TrustedDevice) throws {
        var devices = loadTrustedDevices()
        devices.removeAll { $0.publicKeyHex == device.publicKeyHex }
        devices.append(device)
        let data = try JSONEncoder().encode(devices)
        try saveToKeychain(account: Self.trustedDevicesAccount, data: data)
    }

    /// Remove a device from the trusted list
    public func untrustDevice(publicKeyHex: String) throws {
        var devices = loadTrustedDevices()
        devices.removeAll { $0.publicKeyHex == publicKeyHex }
        let data = try JSONEncoder().encode(devices)
        try saveToKeychain(account: Self.trustedDevicesAccount, data: data)
    }

    /// Check if a device is trusted
    public func isTrusted(publicKeyHex: String) -> Bool {
        loadTrustedDevices().contains { $0.publicKeyHex == publicKeyHex }
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(account: String, data: Data) throws {
        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyManagerError.keychainWriteFailed(status)
        }
    }

    private func loadFromKeychain(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyManagerError.keychainReadFailed(status)
        }
        return data
    }
}

public enum KeyManagerError: Error {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
}
