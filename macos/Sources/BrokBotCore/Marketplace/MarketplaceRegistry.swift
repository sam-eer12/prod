import CryptoKit
import Foundation

/// Outcome of Ed25519 signature verification on a `ConnectorManifest`.
public enum ManifestVerificationResult: Sendable, Equatable {
    case verified(keyId: String)
    case unsignedTemplate
    case untrustedKey(keyId: String)
    case invalidSignature
    case unsupportedAlgorithm(String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var isTamperedOrInvalid: Bool {
        switch self {
        case .invalidSignature, .unsupportedAlgorithm:
            return true
        case .verified, .unsignedTemplate, .untrustedKey:
            return false
        }
    }

    public var badgeLabel: String {
        switch self {
        case .verified(let keyId):
            return "Ed25519 Verified (\(keyId))"
        case .unsignedTemplate:
            return "Starter Dev Template"
        case .untrustedKey(let keyId):
            return "Untrusted Key (\(keyId))"
        case .invalidSignature:
            return "Invalid Signature"
        case .unsupportedAlgorithm(let algo):
            return "Unsupported Alg (\(algo))"
        }
    }
}

/// Errors thrown when validating or installing a remote/bundled `ConnectorManifest`.
public enum MarketplaceError: Error, LocalizedError, Sendable, Equatable {
    case invalidCatalogURL(String)
    case httpError(statusCode: Int)
    case validationFailed([String])
    case signatureRejected(ManifestVerificationResult)
    case noCatalogAvailable

    public var errorDescription: String? {
        switch self {
        case .invalidCatalogURL(let value):
            return "Invalid marketplace catalog URL: \(value)"
        case .httpError(let code):
            return "Marketplace registry returned HTTP \(code)."
        case .validationFailed(let errors):
            return "Manifest validation failed: \(errors.joined(separator: "; "))"
        case .signatureRejected(let result):
            return "Connector rejected by signature verifier: \(result.badgeLabel)."
        case .noCatalogAvailable:
            return "No remote, cached, or bundled marketplace catalog could be loaded."
        }
    }
}

/// Validates `ConnectorManifest` payloads against the rules of `connector-manifest.schema.json`.
public enum ManifestValidator {
    private static let supportedTransports: Set<String> = [
        "tcp_jsonrpc",
        "rest_http",
        "mcp_streamable_http",
        "mcp_stdio"
    ]
    private static let supportedAuthTypes: Set<String> = [
        "none",
        "oauth2_pkce",
        "api_key",
        "bearer"
    ]

    public static func validate(_ manifest: ConnectorManifest) -> [String] {
        var errors: [String] = []

        if manifest.id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
            errors.append("id '\(manifest.id)' must be kebab-case")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("name cannot be empty")
        }
        if manifest.version.range(of: #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) == nil {
            errors.append("version '\(manifest.version)' must be valid SemVer")
        }
        if manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("description cannot be empty")
        }
        if !supportedTransports.contains(manifest.transport.type) {
            errors.append("unsupported transport.type '\(manifest.transport.type)'")
        }
        if manifest.transport.type == "mcp_streamable_http" || manifest.transport.type == "rest_http" {
            if let baseUrl = manifest.transport.baseUrl, URL(string: baseUrl)?.host == nil {
                errors.append("transport.baseUrl must be a valid URI")
            } else if manifest.transport.baseUrl == nil {
                errors.append("transport.baseUrl is required for \(manifest.transport.type)")
            }
        }
        if manifest.transport.type == "tcp_jsonrpc" {
            if let port = manifest.transport.port, !(1...65535).contains(port) {
                errors.append("transport.port out of range")
            }
        }
        if manifest.transport.type == "mcp_stdio" &&
            (manifest.transport.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            errors.append("transport.command is required for mcp_stdio")
        }
        if !supportedAuthTypes.contains(manifest.auth.type) {
            errors.append("unsupported auth.type '\(manifest.auth.type)'")
        }
        if manifest.tools.isEmpty {
            errors.append("tools array must contain at least one tool")
        }
        for tool in manifest.tools {
            if tool.name.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) == nil {
                errors.append("tool name '\(tool.name)' must be snake_case")
            }
        }
        if manifest.signature.algorithm.lowercased() != "ed25519" {
            errors.append("signature.algorithm must be 'ed25519'")
        }
        if manifest.signature.keyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            manifest.signature.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("signature.keyId and signature.value are required")
        }

        return errors
    }
}

/// Canonical JSON + CryptoKit Curve25519 Ed25519 signing and verification for connector manifests.
public enum ManifestSignatureVerifier {
    public static let unsignedTemplateMarker = "unsigned-starter-template"

    private struct SignablePayload: Encodable {
        let id: String
        let name: String
        let version: String
        let description: String
        let manifestPath: String?
        let platforms: [String]?
        let transport: ConnectorTransport
        let auth: ConnectorAuth
        let permissions: [String]
        let tools: [ConnectorToolSpec]
    }

    /// Produces deterministic canonical UTF-8 bytes over all manifest fields except `signature`.
    public static func canonicalSigningPayload(for manifest: ConnectorManifest) throws -> Data {
        let payload = SignablePayload(
            id: manifest.id,
            name: manifest.name,
            version: manifest.version,
            description: manifest.description,
            manifestPath: manifest.manifestPath,
            platforms: manifest.platforms,
            transport: manifest.transport,
            auth: manifest.auth,
            permissions: manifest.permissions,
            tools: manifest.tools
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// Signs `manifest` using an Ed25519 `Curve25519.Signing.PrivateKey`.
    public static func sign(
        manifest: ConnectorManifest,
        privateKey: Curve25519.Signing.PrivateKey,
        keyId: String
    ) throws -> ConnectorManifest {
        let canonical = try canonicalSigningPayload(for: manifest)
        let signatureBytes = try privateKey.signature(for: canonical)
        var signed = manifest
        signed.signature = ConnectorSignature(
            algorithm: "ed25519",
            keyId: keyId,
            value: signatureBytes.base64EncodedString()
        )
        return signed
    }

    /// Verifies `manifest.signature` against `trustedPublicKeys` (raw 32-byte Ed25519 keys keyed by `keyId`).
    public static func verify(
        manifest: ConnectorManifest,
        trustedPublicKeys: [String: Data]
    ) -> ManifestVerificationResult {
        guard manifest.signature.algorithm.lowercased() == "ed25519" else {
            return .unsupportedAlgorithm(manifest.signature.algorithm)
        }

        if manifest.signature.value == unsignedTemplateMarker {
            return .unsignedTemplate
        }

        guard let rawPublicKey = trustedPublicKeys[manifest.signature.keyId] else {
            return .untrustedKey(keyId: manifest.signature.keyId)
        }

        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey),
              let signatureData = Data(base64Encoded: manifest.signature.value),
              let canonical = try? canonicalSigningPayload(for: manifest) else {
            return .invalidSignature
        }

        return publicKey.isValidSignature(signatureData, for: canonical)
            ? .verified(keyId: manifest.signature.keyId)
            : .invalidSignature
    }
}

/// Catalog entry combining a decoded manifest with its schema validation and Ed25519 signature status.
public struct MarketplaceCatalogEntry: Identifiable, Sendable, Equatable {
    public var id: String { manifest.id }
    public let manifest: ConnectorManifest
    public let verification: ManifestVerificationResult
    public let validationErrors: [String]

    public var isInstallableWithoutOverride: Bool {
        validationErrors.isEmpty && verification.isVerified
    }

    public init(
        manifest: ConnectorManifest,
        verification: ManifestVerificationResult,
        validationErrors: [String]
    ) {
        self.manifest = manifest
        self.verification = verification
        self.validationErrors = validationErrors
    }
}

/// Fetches, caches, validates, and Ed25519-verifies remote or bundled Marketplace connector catalogs.
public actor MarketplaceRegistry {
    public static var defaultCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("BrokBot", isDirectory: true)
            .appendingPathComponent("marketplace-catalog-cache.json", isDirectory: false)
    }

    private let urlSession: URLSession
    private let cacheURL: URL
    private var trustedPublicKeys: [String: Data]

    public init(
        urlSession: URLSession = .shared,
        cacheURL: URL = MarketplaceRegistry.defaultCacheURL,
        trustedPublicKeys: [String: Data] = [:]
    ) {
        self.urlSession = urlSession
        self.cacheURL = cacheURL
        self.trustedPublicKeys = trustedPublicKeys
    }

    public func registerTrustedPublicKey(_ rawKey: Data, for keyId: String) {
        trustedPublicKeys[keyId] = rawKey
    }

    /// Loads and verifies `catalog.json` from `remoteURL` (when provided), falling back to disk cache or `bundledFallbackData`.
    public func loadCatalog(
        remoteURL: URL? = nil,
        bundledFallbackData: Data? = nil
    ) async throws -> [MarketplaceCatalogEntry] {
        var catalogData: Data?

        if let remoteURL {
            guard let scheme = remoteURL.scheme?.lowercased(),
                  (scheme == "https" || scheme == "http"),
                  remoteURL.host != nil else {
                throw MarketplaceError.invalidCatalogURL(remoteURL.absoluteString)
            }
            var request = URLRequest(url: remoteURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw MarketplaceError.httpError(statusCode: http.statusCode)
            }
            catalogData = data
            try? persistCache(data)
        }

        if catalogData == nil, FileManager.default.fileExists(atPath: cacheURL.path) {
            catalogData = try? Data(contentsOf: cacheURL)
        }

        if catalogData == nil {
            catalogData = bundledFallbackData
        }

        guard let finalData = catalogData else {
            throw MarketplaceError.noCatalogAvailable
        }

        let catalog = try ConnectorCatalog.decode(from: finalData)
        return catalog.connectors.map { manifest in
            let validationErrors = ManifestValidator.validate(manifest)
            let verification = ManifestSignatureVerifier.verify(
                manifest: manifest,
                trustedPublicKeys: trustedPublicKeys
            )
            return MarketplaceCatalogEntry(
                manifest: manifest,
                verification: verification,
                validationErrors: validationErrors
            )
        }
    }

    /// Enforces schema validation and Ed25519 signature trust before allowing installation.
    public func validateForInstallation(
        _ manifest: ConnectorManifest,
        allowUnsignedTemplates: Bool = false
    ) throws {
        let errors = ManifestValidator.validate(manifest)
        if !errors.isEmpty {
            throw MarketplaceError.validationFailed(errors)
        }

        let verification = ManifestSignatureVerifier.verify(
            manifest: manifest,
            trustedPublicKeys: trustedPublicKeys
        )

        switch verification {
        case .verified:
            return
        case .unsignedTemplate:
            if allowUnsignedTemplates {
                return
            }
            throw MarketplaceError.signatureRejected(verification)
        case .untrustedKey, .invalidSignature, .unsupportedAlgorithm:
            throw MarketplaceError.signatureRejected(verification)
        }
    }

    /// Materializes a verified `ConnectorManifest` + user setup fields into an `MCPServerConnection`.
    public nonisolated func makeConnection(
        from manifest: ConnectorManifest,
        configValues: [String: String] = [:]
    ) -> MCPServerConnection {
        let transportKind = MCPTransportKind(rawValue: manifest.transport.type) ?? .streamableHTTP
        let authMode: MCPAuthMode
        switch manifest.auth.type {
        case "oauth2_pkce": authMode = .oauthPKCE
        case "bearer", "api_key": authMode = .bearerToken
        default: authMode = .none
        }

        let tools = manifest.tools.map { spec in
            MCPDiscoveredTool(
                name: spec.name,
                description: spec.description,
                inputSchema: spec.inputSchema,
                readOnlyHint: !spec.requiresApproval,
                destructiveHint: spec.requiresApproval,
                requiresApproval: spec.requiresApproval
            )
        }

        let host = configValues["host"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil ?? manifest.transport.host ?? "127.0.0.1"
        let port = configValues["port"].flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? manifest.transport.port
            ?? 9876
        let clientID = configValues["client_id"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        let isGoogleStatelessMCP = (manifest.transport.baseUrl?.lowercased().contains("mcp.googleapis.com") ?? false)
            || manifest.id == "gmail-mcp"
            || manifest.id == "google-drive-mcp"
            || manifest.id == "google-calendar-mcp"
            || manifest.id == "google-docs-mcp"
            || manifest.id == "google-slides-mcp"
            || manifest.id == "google-sheets-mcp"
        let allReadOnly = manifest.tools.allSatisfy { !$0.requiresApproval }

        return MCPServerConnection(
            id: manifest.id,
            name: manifest.name,
            presetID: manifest.id,
            transportKind: transportKind,
            endpointURL: manifest.transport.baseUrl ?? "http://\(host):\(port)",
            stdioCommand: manifest.transport.command,
            stdioArgs: manifest.transport.args ?? [],
            tcpHost: host,
            tcpPort: port,
            authMode: authMode,
            readOnly: allReadOnly,
            statelessMode: isGoogleStatelessMCP,
            requireApprovalForWrites: true,
            isEnabled: true,
            clientID: clientID,
            scopes: manifest.auth.scopes ?? [],
            authorizationEndpoint: manifest.auth.authorizationEndpoint,
            tokenEndpoint: manifest.auth.tokenEndpoint,
            redirectURI: manifest.auth.redirectUri ?? MCPServerConnection.defaultRedirectURI,
            discoveredTools: tools,
            notes: manifest.description
        )
    }

    private func persistCache(_ data: Data) throws {
        let fm = FileManager.default
        let dir = cacheURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: cacheURL, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
