import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Decrypted payload persisted inside `vault.enc`.
public struct VaultPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var memoryEntries: [MemoryEntry]
    public var providerAPIKeys: [String: String]
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case memoryEntries
        case providerAPIKeys
        case updatedAt
    }

    public init(
        schemaVersion: Int = 1,
        memoryEntries: [MemoryEntry] = [],
        providerAPIKeys: [String: String] = [:],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.memoryEntries = memoryEntries
        self.providerAPIKeys = providerAPIKeys
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.memoryEntries = try container.decodeIfPresent([MemoryEntry].self, forKey: .memoryEntries) ?? []
        self.providerAPIKeys = try container.decodeIfPresent([String: String].self, forKey: .providerAPIKeys) ?? [:]
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// Errors surfaced by `BrokVaultManager` and `VaultKeyProvider` implementations.
public enum BrokVaultError: Error, LocalizedError, Sendable, Equatable {
    case vaultLocked
    case authenticationFailed(String)
    case integrityCheckFailed
    case keyDerivationFailed
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "The Brok Bot Vault is locked. Unlock it before reading or modifying secrets."
        case .authenticationFailed(let reason):
            return "Vault authentication failed: \(reason)"
        case .integrityCheckFailed:
            return "Vault integrity check failed. The vault file may be tampered with or the wrong key was supplied."
        case .keyDerivationFailed:
            return "Failed to derive a cryptographic key for the Brok Bot Vault."
        case .ioError(let reason):
            return "Vault I/O error: \(reason)"
        }
    }
}

/// Supplies the 256-bit master key used to derive per-write AES-GCM encryption keys.
public protocol VaultKeyProvider: Sendable {
    func retrieveOrCreateMasterKey(promptReason: String) async throws -> SymmetricKey
}

/// Hardware/Keychain-backed master key provider gated by `LocalAuthentication` Touch ID when available.
public final class KeychainBiometricKeyProvider: VaultKeyProvider, Sendable {
    public let service: String
    public let account: String
    public let requireBiometrics: Bool

    public init(
        service: String = "org.brokbot.vault",
        account: String = "master_key",
        requireBiometrics: Bool = true
    ) {
        self.service = service
        self.account = account
        self.requireBiometrics = requireBiometrics
    }

    public func retrieveOrCreateMasterKey(promptReason: String) async throws -> SymmetricKey {
        try await evaluateAuthenticationIfNeeded(reason: promptReason)
        return try readOrCreateKeychainKey()
    }

    private func evaluateAuthenticationIfNeeded(reason: String) async throws {
        guard requireBiometrics else { return }

        let context = LAContext()
        var authError: NSError?
        let canEvaluateBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &authError
        )

        if canEvaluateBiometrics {
            do {
                let authenticated = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
                guard authenticated else {
                    throw BrokVaultError.authenticationFailed("Biometric verification returned false.")
                }
            } catch let vaultError as BrokVaultError {
                throw vaultError
            } catch {
                throw BrokVaultError.authenticationFailed(error.localizedDescription)
            }
            return
        }

        // Fall back cleanly when Touch ID / biometric hardware is unavailable or unenrolled.
        if let laError = authError as? LAError {
            switch laError.code {
            case .biometryLockout:
                throw BrokVaultError.authenticationFailed("Biometric authentication is locked out.")
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return
            default:
                return
            }
        }
    }

    private func readOrCreateKeychainKey() throws -> SymmetricKey {
        if let existing = try queryKeychainKey() {
            return existing
        }

        var rawKey = Data(count: 32)
        defer {
            if !rawKey.isEmpty {
                rawKey.resetBytes(in: 0..<rawKey.count)
            }
        }

        let rngStatus = rawKey.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard rngStatus == errSecSuccess else {
            throw BrokVaultError.keyDerivationFailed
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: rawKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let existing = try queryKeychainKey() {
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw BrokVaultError.authenticationFailed(Self.securityErrorMessage(for: addStatus))
        }

        return SymmetricKey(data: rawKey)
    }

    private func queryKeychainKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw BrokVaultError.authenticationFailed(Self.securityErrorMessage(for: status))
        }

        guard var keyData = result as? Data else {
            throw BrokVaultError.keyDerivationFailed
        }
        defer {
            if !keyData.isEmpty {
                keyData.resetBytes(in: 0..<keyData.count)
            }
        }

        guard keyData.count == 32 else {
            throw BrokVaultError.keyDerivationFailed
        }

        return SymmetricKey(data: keyData)
    }

    private static func securityErrorMessage(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "Keychain error \(status)"
    }
}

/// Deterministic in-memory key provider for headless unit tests and ephemeral instances.
public struct StaticVaultKeyProvider: VaultKeyProvider, Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.key = key
    }

    public init(seed: String) {
        let ikm = SymmetricKey(data: Data(seed.utf8))
        let salt = Data("org.brokbot.vault.static.salt.v1".utf8)
        let info = Data("org.brokbot.vault.static.v1".utf8)
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    public func retrieveOrCreateMasterKey(promptReason: String) async throws -> SymmetricKey {
        key
    }
}

/// HKDF-SHA256 passphrase key provider for headless operation and user passphrase mode.
public struct PassphraseVaultKeyProvider: VaultKeyProvider, Sendable {
    private let passphraseData: Data
    private let salt: Data
    private let info: Data

    public init(
        passphrase: String,
        salt: Data = Data("org.brokbot.vault.passphrase.salt.v1".utf8),
        info: Data = Data("org.brokbot.vault.passphrase.v1".utf8)
    ) {
        self.passphraseData = Data(passphrase.utf8)
        self.salt = salt
        self.info = info
    }

    public func retrieveOrCreateMasterKey(promptReason: String) async throws -> SymmetricKey {
        guard !passphraseData.isEmpty else {
            throw BrokVaultError.keyDerivationFailed
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passphraseData),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }
}

/// Hardware-backed AES-256-GCM encrypted vault storing Space 2 Permanent Memory and BYOK API keys.
public actor BrokVaultManager: BrokVaultStoring {
    public static var defaultVaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("BrokBot", isDirectory: true)
            .appendingPathComponent("vault.enc", isDirectory: false)
    }

    private static let envelopeMagic = Data("BRKV".utf8)
    private static let envelopeVersion: UInt8 = 1
    private static let saltLength = 32
    private static let minimumNonceAndTagLength = 12 + 16
    private static let hkdfInfo = Data("org.brokbot.vault.v1".utf8)
    private static let authenticatedData = Data("org.brokbot.vault.v1".utf8)

    public nonisolated let vaultURL: URL
    private let keyProvider: any VaultKeyProvider
    private var masterKey: SymmetricKey?

    public init(
        vaultURL: URL = BrokVaultManager.defaultVaultURL,
        keyProvider: any VaultKeyProvider = KeychainBiometricKeyProvider()
    ) {
        self.vaultURL = vaultURL
        self.keyProvider = keyProvider
    }

    /// Returns whether the vault is currently unlocked in memory.
    public func isUnlocked() -> Bool {
        masterKey != nil
    }

    /// Authenticates via `VaultKeyProvider`, verifies any existing vault file, and unlocks the vault.
    public func unlock(reason: String = "Unlock Brok Bot Vault") async throws {
        let retrievedKey: SymmetricKey
        do {
            retrievedKey = try await keyProvider.retrieveOrCreateMasterKey(promptReason: reason)
        } catch let vaultError as BrokVaultError {
            throw vaultError
        } catch {
            throw BrokVaultError.authenticationFailed(error.localizedDescription)
        }

        if FileManager.default.fileExists(atPath: vaultURL.path) {
            _ = try readPayload(using: retrievedKey)
        }

        masterKey = retrievedKey
    }

    /// Locks the vault and clears the in-memory master key reference.
    public func lock() {
        masterKey = nil
    }

    /// Loads all permanent memory entries from the encrypted vault.
    public func loadEntries() async throws -> [MemoryEntry] {
        let key = try requireUnlockedKey()
        return try readPayload(using: key).memoryEntries
    }

    /// Overwrites permanent memory entries inside the encrypted vault using a fresh per-write salt.
    public func saveEntries(_ entries: [MemoryEntry]) async throws {
        let key = try requireUnlockedKey()
        var payload = try readPayload(using: key)
        payload.memoryEntries = entries
        payload.updatedAt = Date()
        try writePayload(payload, using: key)
    }

    /// Retrieves the stored BYOK API key for `provider`, or `nil` if unconfigured.
    public func apiKey(for provider: BYOKProviderKind) async throws -> String? {
        let key = try requireUnlockedKey()
        let payload = try readPayload(using: key)
        guard let value = payload.providerAPIKeys[provider.rawValue], !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Encrypts and persists a BYOK API key for `provider`.
    public func setAPIKey(_ apiKey: String, for provider: BYOKProviderKind) async throws {
        let key = try requireUnlockedKey()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = try readPayload(using: key)

        if trimmed.isEmpty {
            payload.providerAPIKeys.removeValue(forKey: provider.rawValue)
        } else {
            payload.providerAPIKeys[provider.rawValue] = trimmed
        }
        payload.updatedAt = Date()
        try writePayload(payload, using: key)
    }

    /// Deletes the BYOK API key for `provider` and rewrites `vault.enc` with a fresh salt and nonce.
    public func deleteAPIKey(for provider: BYOKProviderKind) async throws {
        let key = try requireUnlockedKey()
        var payload = try readPayload(using: key)
        payload.providerAPIKeys.removeValue(forKey: provider.rawValue)
        payload.updatedAt = Date()
        try writePayload(payload, using: key)
    }

    /// Returns all BYOK providers that currently have a non-empty API key stored in the vault.
    public func configuredProviders() async throws -> [BYOKProviderKind] {
        let key = try requireUnlockedKey()
        let payload = try readPayload(using: key)
        return BYOKProviderKind.allCases.filter { provider in
            guard let stored = payload.providerAPIKeys[provider.rawValue] else { return false }
            return !stored.isEmpty
        }
    }

    // MARK: - Private Encryption & Atomic I/O

    private func requireUnlockedKey() throws -> SymmetricKey {
        guard let masterKey else {
            throw BrokVaultError.vaultLocked
        }
        return masterKey
    }

    private func readPayload(using masterKey: SymmetricKey) throws -> VaultPayload {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: vaultURL.path) else {
            return VaultPayload()
        }

        let envelope: Data
        do {
            envelope = try Data(contentsOf: vaultURL)
        } catch {
            throw BrokVaultError.ioError(error.localizedDescription)
        }

        let headerLength = Self.envelopeMagic.count + 1 + Self.saltLength
        guard envelope.count >= headerLength + Self.minimumNonceAndTagLength else {
            throw BrokVaultError.integrityCheckFailed
        }

        guard envelope.prefix(Self.envelopeMagic.count) == Self.envelopeMagic else {
            throw BrokVaultError.integrityCheckFailed
        }

        let versionIndex = Self.envelopeMagic.count
        guard envelope[versionIndex] == Self.envelopeVersion else {
            throw BrokVaultError.integrityCheckFailed
        }

        let saltStart = versionIndex + 1
        let saltEnd = saltStart + Self.saltLength
        var salt = envelope.subdata(in: saltStart..<saltEnd)
        defer {
            if !salt.isEmpty {
                salt.resetBytes(in: 0..<salt.count)
            }
        }

        let combined = envelope.subdata(in: saltEnd..<envelope.count)
        let derivedKey = deriveEncryptionKey(from: masterKey, salt: salt)

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw BrokVaultError.integrityCheckFailed
        }

        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                sealedBox,
                using: derivedKey,
                authenticating: Self.authenticatedData
            )
        } catch {
            throw BrokVaultError.integrityCheckFailed
        }

        defer {
            if !plaintext.isEmpty {
                plaintext.resetBytes(in: 0..<plaintext.count)
            }
        }

        do {
            return try JSONDecoder().decode(VaultPayload.self, from: plaintext)
        } catch {
            throw BrokVaultError.integrityCheckFailed
        }
    }

    private func writePayload(_ payload: VaultPayload, using masterKey: SymmetricKey) throws {
        var salt = try generateRandomSalt(length: Self.saltLength)
        defer {
            if !salt.isEmpty {
                salt.resetBytes(in: 0..<salt.count)
            }
        }

        let derivedKey = deriveEncryptionKey(from: masterKey, salt: salt)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var plaintext: Data
        do {
            plaintext = try encoder.encode(payload)
        } catch {
            throw BrokVaultError.ioError("Failed to encode vault payload: \(error.localizedDescription)")
        }

        defer {
            if !plaintext.isEmpty {
                plaintext.resetBytes(in: 0..<plaintext.count)
            }
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(
                plaintext,
                using: derivedKey,
                authenticating: Self.authenticatedData
            )
        } catch {
            throw BrokVaultError.keyDerivationFailed
        }

        guard let combined = sealedBox.combined else {
            throw BrokVaultError.keyDerivationFailed
        }

        var envelope = Data(capacity: Self.envelopeMagic.count + 1 + Self.saltLength + combined.count)
        envelope.append(Self.envelopeMagic)
        envelope.append(Self.envelopeVersion)
        envelope.append(salt)
        envelope.append(combined)

        try writeAtomicallyWithRestrictedPermissions(envelope)
    }

    private func deriveEncryptionKey(from masterKey: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: Self.hkdfInfo,
            outputByteCount: 32
        )
    }

    private func generateRandomSalt(length: Int) throws -> Data {
        var salt = Data(count: length)
        let status = salt.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, length, baseAddress)
        }
        guard status == errSecSuccess else {
            if !salt.isEmpty {
                salt.resetBytes(in: 0..<salt.count)
            }
            throw BrokVaultError.keyDerivationFailed
        }
        return salt
    }

    private func writeAtomicallyWithRestrictedPermissions(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = vaultURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let tempURL = directory.appendingPathComponent(".\(vaultURL.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: tempURL) }

            guard fileManager.createFile(
                atPath: tempURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw BrokVaultError.ioError("Failed to create temporary vault file at \(tempURL.path)")
            }

            if fileManager.fileExists(atPath: vaultURL.path) {
                _ = try fileManager.replaceItemAt(vaultURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: vaultURL)
            }

            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
        } catch let vaultError as BrokVaultError {
            throw vaultError
        } catch {
            throw BrokVaultError.ioError(error.localizedDescription)
        }
    }
}
