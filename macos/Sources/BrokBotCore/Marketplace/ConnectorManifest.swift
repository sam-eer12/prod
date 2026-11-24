import Foundation

/// Lightweight, Sendable recursive JSON value used for optional tool input schemas.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .integer(int)
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Wire transport configuration declared by a connector manifest.
public struct ConnectorTransport: Codable, Sendable, Equatable {
    public var type: String
    public var host: String?
    public var port: Int?
    public var baseUrl: String?
    public var command: String?
    public var args: [String]?
    public var pollingIntervalSeconds: Int?

    public init(
        type: String,
        host: String? = nil,
        port: Int? = nil,
        baseUrl: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        pollingIntervalSeconds: Int? = nil
    ) {
        self.type = type
        self.host = host
        self.port = port
        self.baseUrl = baseUrl
        self.command = command
        self.args = args
        self.pollingIntervalSeconds = pollingIntervalSeconds
    }
}

/// Dynamic setup field descriptor used to generate connector setup forms.
public struct ConnectorSetupField: Codable, Identifiable, Sendable, Equatable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var secret: Bool
    public var required: Bool
    public var defaultValue: String?
    public var placeholder: String?

    public init(
        key: String,
        label: String,
        secret: Bool,
        required: Bool,
        defaultValue: String? = nil,
        placeholder: String? = nil
    ) {
        self.key = key
        self.label = label
        self.secret = secret
        self.required = required
        self.defaultValue = defaultValue
        self.placeholder = placeholder
    }
}

/// Authentication metadata declared by a connector manifest.
public struct ConnectorAuth: Codable, Sendable, Equatable {
    public var type: String
    public var authorizationEndpoint: String?
    public var tokenEndpoint: String?
    public var redirectUri: String?
    public var scopes: [String]?
    public var setupFields: [ConnectorSetupField]?

    public init(
        type: String,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        redirectUri: String? = nil,
        scopes: [String]? = nil,
        setupFields: [ConnectorSetupField]? = nil
    ) {
        self.type = type
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectUri = redirectUri
        self.scopes = scopes
        self.setupFields = setupFields
    }
}

/// Cryptographic signature envelope for verifying remote manifests.
public struct ConnectorSignature: Codable, Sendable, Equatable {
    public var algorithm: String
    public var keyId: String
    public var value: String

    public init(algorithm: String, keyId: String, value: String) {
        self.algorithm = algorithm
        self.keyId = keyId
        self.value = value
    }
}

/// Tool capability exposed by a marketplace connector.
public struct ConnectorToolSpec: Codable, Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var requiresApproval: Bool
    public var inputSchema: [String: JSONValue]?

    public init(
        name: String,
        description: String,
        requiresApproval: Bool,
        inputSchema: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.description = description
        self.requiresApproval = requiresApproval
        self.inputSchema = inputSchema
    }
}

/// Declarative connector manifest matching `marketplace/schema/connector-manifest.schema.json`.
public struct ConnectorManifest: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var manifestPath: String?
    public var platforms: [String]?
    public var transport: ConnectorTransport
    public var auth: ConnectorAuth
    public var permissions: [String]
    public var tools: [ConnectorToolSpec]
    public var signature: ConnectorSignature

    public init(
        id: String,
        name: String,
        version: String,
        description: String,
        manifestPath: String? = nil,
        platforms: [String]? = nil,
        transport: ConnectorTransport,
        auth: ConnectorAuth,
        permissions: [String],
        tools: [ConnectorToolSpec],
        signature: ConnectorSignature
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.manifestPath = manifestPath
        self.platforms = platforms
        self.transport = transport
        self.auth = auth
        self.permissions = permissions
        self.tools = tools
        self.signature = signature
    }
}

/// Top-level marketplace catalog matching `marketplace/catalog.json`.
public struct ConnectorCatalog: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var updatedAt: String
    public var connectors: [ConnectorManifest]

    public init(
        schemaVersion: String,
        updatedAt: String,
        connectors: [ConnectorManifest]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.connectors = connectors
    }

    /// Decodes a `ConnectorCatalog` from raw JSON data.
    public static func decode(from data: Data) throws -> ConnectorCatalog {
        try JSONDecoder().decode(ConnectorCatalog.self, from: data)
    }
}
