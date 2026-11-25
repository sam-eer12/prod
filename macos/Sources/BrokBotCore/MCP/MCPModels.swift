import Foundation

// MARK: - JSONValue Helpers

public extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Encodes a `[String: JSONValue]` dictionary into compact sorted JSON string.
    static func encodeObjectString(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(object),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Decodes a JSON string into a `[String: JSONValue]` object, returning empty dictionary on failure.
    static func decodeObject(from jsonString: String) -> [String: JSONValue] {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

// MARK: - Transport, Auth & Connection Models

/// Wire transport protocol for an MCP server or local bridge connection.
public enum MCPTransportKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case streamableHTTP = "mcp_streamable_http"
    case stdio = "mcp_stdio"
    case tcpJSONRPC = "tcp_jsonrpc"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .streamableHTTP: return "Streamable HTTP"
        case .stdio: return "Local Stdio"
        case .tcpJSONRPC: return "TCP JSON-RPC"
        }
    }
}

/// Authentication mechanism for a Streamable HTTP MCP server connection.
public enum MCPAuthMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case oauthPKCE = "oauth2_pkce"
    case bearerToken = "bearer_token"
    case none = "none"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .oauthPKCE: return "OAuth 2.1 + PKCE"
        case .bearerToken: return "Bearer Token"
        case .none: return "No Auth"
        }
    }
}

/// Tool metadata discovered via MCP `tools/list` or declared in a verified manifest.
public struct MCPDiscoveredTool: Identifiable, Codable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchema: [String: JSONValue]?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var requiresApproval: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
        case readOnlyHint
        case destructiveHint
        case requiresApproval
    }

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: [String: JSONValue]? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        requiresApproval: Bool? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.requiresApproval = requiresApproval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.inputSchema = try container.decodeIfPresent([String: JSONValue].self, forKey: .inputSchema)
        self.readOnlyHint = try container.decodeIfPresent(Bool.self, forKey: .readOnlyHint)
        self.destructiveHint = try container.decodeIfPresent(Bool.self, forKey: .destructiveHint)
        self.requiresApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresApproval)
    }

    /// Converts this discovered MCP tool into a normalized `ToolDefinition` for `BYOKModelClient`.
    public func toBYOKToolDefinition(exposedName: String? = nil) -> ToolDefinition {
        let resolvedName = exposedName ?? name
        let schemaString: String
        if let inputSchema, !inputSchema.isEmpty {
            schemaString = JSONValue.encodeObjectString(inputSchema)
        } else {
            schemaString = "{\"type\":\"object\",\"properties\":{}}"
        }
        return ToolDefinition(
            name: resolvedName,
            description: description.isEmpty ? (title ?? name) : description,
            jsonSchemaParameters: schemaString
        )
    }
}

/// Persisted MCP server or local bridge configuration (non-secret metadata only; tokens & client secrets live in `vault.enc`).
public struct MCPServerConnection: Identifiable, Codable, Sendable, Equatable {
    public static let defaultRedirectURI = "http://127.0.0.1:48912/callback"

    public var id: String
    public var name: String
    public var presetID: String?
    public var transportKind: MCPTransportKind
    public var endpointURL: String
    public var stdioCommand: String?
    public var stdioArgs: [String]
    public var tcpHost: String?
    public var tcpPort: Int?
    public var authMode: MCPAuthMode
    public var readOnly: Bool
    public var statelessMode: Bool
    public var requireApprovalForWrites: Bool
    public var isEnabled: Bool
    public var clientID: String?
    public var scopes: [String]
    public var authorizationEndpoint: String?
    public var tokenEndpoint: String?
    public var redirectURI: String
    public var discoveredTools: [MCPDiscoveredTool]
    public var lastConnectedAt: Date?
    public var protocolVersion: String?
    public var serverName: String?
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case presetID
        case transportKind
        case endpointURL
        case stdioCommand
        case stdioArgs
        case tcpHost
        case tcpPort
        case authMode
        case readOnly
        case statelessMode
        case requireApprovalForWrites
        case isEnabled
        case clientID
        case scopes
        case authorizationEndpoint
        case tokenEndpoint
        case redirectURI
        case discoveredTools
        case lastConnectedAt
        case protocolVersion
        case serverName
        case notes
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        presetID: String? = nil,
        transportKind: MCPTransportKind = .streamableHTTP,
        endpointURL: String,
        stdioCommand: String? = nil,
        stdioArgs: [String] = [],
        tcpHost: String? = nil,
        tcpPort: Int? = nil,
        authMode: MCPAuthMode = .oauthPKCE,
        readOnly: Bool = true,
        statelessMode: Bool = false,
        requireApprovalForWrites: Bool = true,
        isEnabled: Bool = true,
        clientID: String? = nil,
        scopes: [String] = [],
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        redirectURI: String = MCPServerConnection.defaultRedirectURI,
        discoveredTools: [MCPDiscoveredTool] = [],
        lastConnectedAt: Date? = nil,
        protocolVersion: String? = nil,
        serverName: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.transportKind = transportKind
        self.endpointURL = endpointURL
        self.stdioCommand = stdioCommand
        self.stdioArgs = stdioArgs
        self.tcpHost = tcpHost
        self.tcpPort = tcpPort
        self.authMode = authMode
        self.readOnly = readOnly
        self.statelessMode = statelessMode
        self.requireApprovalForWrites = requireApprovalForWrites
        self.isEnabled = isEnabled
        self.clientID = clientID
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectURI = redirectURI
        self.discoveredTools = discoveredTools
        self.lastConnectedAt = lastConnectedAt
        self.protocolVersion = protocolVersion
        self.serverName = serverName
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
        self.transportKind = try container.decodeIfPresent(MCPTransportKind.self, forKey: .transportKind) ?? .streamableHTTP
        self.endpointURL = try container.decodeIfPresent(String.self, forKey: .endpointURL) ?? ""
        self.stdioCommand = try container.decodeIfPresent(String.self, forKey: .stdioCommand)
        self.stdioArgs = try container.decodeIfPresent([String].self, forKey: .stdioArgs) ?? []
        self.tcpHost = try container.decodeIfPresent(String.self, forKey: .tcpHost)
        self.tcpPort = try container.decodeIfPresent(Int.self, forKey: .tcpPort)
        self.authMode = try container.decodeIfPresent(MCPAuthMode.self, forKey: .authMode) ?? .oauthPKCE
        self.readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        self.statelessMode = try container.decodeIfPresent(Bool.self, forKey: .statelessMode) ?? false
        self.requireApprovalForWrites = try container.decodeIfPresent(Bool.self, forKey: .requireApprovalForWrites) ?? true
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        self.scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        self.authorizationEndpoint = try container.decodeIfPresent(String.self, forKey: .authorizationEndpoint)
        self.tokenEndpoint = try container.decodeIfPresent(String.self, forKey: .tokenEndpoint)
        self.redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI) ?? Self.defaultRedirectURI
        self.discoveredTools = try container.decodeIfPresent([MCPDiscoveredTool].self, forKey: .discoveredTools) ?? []
        self.lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        self.protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        self.serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// Logical grouping for built-in hosted MCP server presets.
public enum MCPServerPresetCategory: String, CaseIterable, Identifiable, Sendable {
    case googleWorkspace = "Google Workspace"
    case cloudAndDeploy = "Cloud & Deploy"
    case paymentsAndData = "Payments & Data"
    case devAndObservability = "Dev & Observability"
    case productivityAndDesign = "Productivity & Design"

    public var id: String { rawValue }
}

/// Built-in hosted MCP server presets shipped in Brok Bot Phase 2.
public struct MCPServerPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let category: MCPServerPresetCategory
    public let endpointURL: String
    public let authMode: MCPAuthMode
    public let readOnly: Bool
    public let statelessMode: Bool
    public let scopes: [String]
    public let authorizationEndpoint: String?
    public let tokenEndpoint: String?
    public let setupInstructions: String

    public init(
        id: String,
        name: String,
        subtitle: String,
        category: MCPServerPresetCategory = .devAndObservability,
        endpointURL: String,
        authMode: MCPAuthMode,
        readOnly: Bool,
        statelessMode: Bool,
        scopes: [String],
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        setupInstructions: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.category = category
        self.endpointURL = endpointURL
        self.authMode = authMode
        self.readOnly = readOnly
        self.statelessMode = statelessMode
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.setupInstructions = setupInstructions
    }

    public func makeConnection() -> MCPServerConnection {
        MCPServerConnection(
            id: id,
            name: name,
            presetID: id,
            transportKind: .streamableHTTP,
            endpointURL: endpointURL,
            authMode: authMode,
            readOnly: readOnly,
            statelessMode: statelessMode,
            requireApprovalForWrites: true,
            isEnabled: true,
            scopes: scopes,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            redirectURI: MCPServerConnection.defaultRedirectURI,
            notes: setupInstructions
        )
    }

    // MARK: Google Workspace (Official Stateless Personal Mode MCP)

    public static let gmailPersonal = MCPServerPreset(
        id: "gmail-mcp",
        name: "Gmail (Read-Only)",
        subtitle: "Google Personal Mode · Official Stateless MCP · Threads & Messages",
        category: .googleWorkspace,
        endpointURL: "https://gmailmcp.googleapis.com/mcp/v1",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: true,
        scopes: ["https://www.googleapis.com/auth/gmail.readonly"],
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        setupInstructions: "Personal Mode: In your Google Cloud project (Standard Tier, no billing required), enable Gmail API + Gmail MCP API, create a Desktop OAuth Client ID, paste it below, and click Sign In."
    )

    public static let googleDrivePersonal = MCPServerPreset(
        id: "google-drive-mcp",
        name: "Google Drive (Read-Only)",
        subtitle: "Google Personal Mode · Official Stateless MCP · Search & Inspect Files",
        category: .googleWorkspace,
        endpointURL: "https://drivemcp.googleapis.com/mcp/v1",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: true,
        scopes: ["https://www.googleapis.com/auth/drive.readonly"],
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        setupInstructions: "Personal Mode: In your Google Cloud project (Standard Tier, no billing required), enable Google Drive API + Google Drive MCP API, create a Desktop OAuth Client ID, paste it below, and click Sign In."
    )

    public static let googleDocsPersonal = MCPServerPreset(
        id: "google-docs-mcp",
        name: "Google Docs (Read-Only)",
        subtitle: "Google Personal Mode · Official Stateless MCP · Free Standard Tier (5k/day)",
        category: .googleWorkspace,
        endpointURL: "https://docsmcp.googleapis.com/mcp/v1",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: true,
        scopes: ["https://www.googleapis.com/auth/documents.readonly"],
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        setupInstructions: "Personal Mode: In your Google Cloud project (Standard Tier: 5,000 req/day, no billing required), enable Google Docs API + Google Docs MCP API, create a Desktop OAuth Client ID, paste it below, and click Sign In."
    )

    public static let googleSlidesPersonal = MCPServerPreset(
        id: "google-slides-mcp",
        name: "Google Slides (Read-Only)",
        subtitle: "Google Personal Mode · Official Stateless MCP · Free Standard Tier (5k/day)",
        category: .googleWorkspace,
        endpointURL: "https://slidesmcp.googleapis.com/mcp/v1",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: true,
        scopes: ["https://www.googleapis.com/auth/presentations.readonly"],
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        setupInstructions: "Personal Mode: In your Google Cloud project (Standard Tier: 5,000 req/day, no billing required), enable Google Slides API + Google Slides MCP API, create a Desktop OAuth Client ID, paste it below, and click Sign In."
    )

    public static let googleSheetsPersonal = MCPServerPreset(
        id: "google-sheets-mcp",
        name: "Google Sheets (Read-Only)",
        subtitle: "Google Personal Mode · Official Stateless MCP · Spreadsheets & Ranges",
        category: .googleWorkspace,
        endpointURL: "https://sheetsmcp.googleapis.com/mcp/v1",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: true,
        scopes: ["https://www.googleapis.com/auth/spreadsheets.readonly"],
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        setupInstructions: "Personal Mode: In your Google Cloud project (Standard Tier, no billing required), enable Google Sheets API + Google Sheets MCP API, create a Desktop OAuth Client ID, paste it below, and click Sign In."
    )

    public static let googleCalendarPersonal = MCPServerPreset(
        id: "google-calendar-personal",
        name: "Google Calendar (Read-Only)",
        subtitle: "Google Personal Mode · Official Stateless MCP · Zero Polling",
        category: .googleWorkspace,
        endpointURL: "https://calendarmcp.googleapis.com/mcp/v1",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: true,
        scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        setupInstructions: "Personal Mode Beta: In your own Google Cloud project, enable Google Calendar API + Google Calendar MCP API, create a Desktop OAuth Client ID, paste it below, and click Sign In. Calls run on-demand with server-driven MCP approvals."
    )

    // MARK: Cloud & Deploy

    public static let vercelHosted = MCPServerPreset(
        id: "vercel-mcp",
        name: "Vercel (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Projects, Deployments & Logs",
        category: .cloudAndDeploy,
        endpointURL: "https://mcp.vercel.com",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Vercel OAuth 2.1 + PKCE using MCP Dynamic Client Registration."
    )

    public static let railwayHosted = MCPServerPreset(
        id: "railway-mcp",
        name: "Railway (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Projects, Services & Logs",
        category: .cloudAndDeploy,
        endpointURL: "https://mcp.railway.com",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Railway OAuth 2.1 + PKCE using MCP Dynamic Client Registration."
    )

    public static let cloudflareHosted = MCPServerPreset(
        id: "cloudflare-mcp",
        name: "Cloudflare (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Workers, DNS & Logs",
        category: .cloudAndDeploy,
        endpointURL: "https://mcp.cloudflare.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Cloudflare OAuth 2.1 + PKCE or switch Auth Mode to Bearer Token and paste a Cloudflare API Token."
    )

    public static let netlifyHosted = MCPServerPreset(
        id: "netlify-mcp",
        name: "Netlify (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Sites & Deploys",
        category: .cloudAndDeploy,
        endpointURL: "https://mcp.netlify.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Netlify OAuth 2.1 + PKCE or switch Auth Mode to Bearer Token and paste a Netlify Personal Access Token."
    )

    public static let renderHosted = MCPServerPreset(
        id: "render-mcp",
        name: "Render (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Services, Deploys & Logs",
        category: .cloudAndDeploy,
        endpointURL: "https://mcp.render.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Render OAuth 2.1 + PKCE or switch Auth Mode to Bearer Token and paste a Render API Key."
    )

    // MARK: Payments & Data

    public static let stripeHosted = MCPServerPreset(
        id: "stripe-mcp",
        name: "Stripe (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Customers, Invoices & Subscriptions",
        category: .paymentsAndData,
        endpointURL: "https://mcp.stripe.com",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Stripe OAuth 2.1 + PKCE or switch Auth Mode to Bearer Token and paste a Stripe Restricted API Key (`rk_live_...`)."
    )

    public static let supabaseHosted = MCPServerPreset(
        id: "supabase-mcp",
        name: "Supabase (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Projects, Tables & Logs",
        category: .paymentsAndData,
        endpointURL: "https://mcp.supabase.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Supabase OAuth 2.1 + PKCE or switch Auth Mode to Bearer Token and paste a Supabase Personal Access Token (`sbp_...`)."
    )

    public static let neonHosted = MCPServerPreset(
        id: "neon-mcp",
        name: "Neon (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Serverless Postgres & Branches",
        category: .paymentsAndData,
        endpointURL: "https://mcp.neon.tech/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Neon OAuth 2.1 + PKCE or switch Auth Mode to Bearer Token and paste a Neon API Key."
    )

    // MARK: Dev & Observability

    public static let githubHosted = MCPServerPreset(
        id: "github-mcp",
        name: "GitHub (Hosted MCP)",
        subtitle: "Official GitHub remote MCP · Repos, Issues & Pull Requests",
        category: .devAndObservability,
        endpointURL: "https://api.githubcopilot.com/mcp/",
        authMode: .bearerToken,
        readOnly: true,
        statelessMode: false,
        scopes: ["repo", "read:user"],
        setupInstructions: "Paste a scoped GitHub Personal Access Token (`github_pat_...`) to store inside `vault.enc`."
    )

    public static let sentryHosted = MCPServerPreset(
        id: "sentry-mcp",
        name: "Sentry (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Issues, Traces & Events",
        category: .devAndObservability,
        endpointURL: "https://mcp.sentry.dev/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Sentry OAuth 2.1 + PKCE using MCP Dynamic Client Registration."
    )

    public static let posthogHosted = MCPServerPreset(
        id: "posthog-mcp",
        name: "PostHog (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Insights, Flags & Events",
        category: .devAndObservability,
        endpointURL: "https://mcp.posthog.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with PostHog OAuth 2.1 + PKCE or switch Auth Mode to Bearer Token and paste a PostHog Personal API Key."
    )

    public static let linearReadOnly = MCPServerPreset(
        id: "linear-readonly",
        name: "Linear (Read-Only)",
        subtitle: "Official hosted Streamable HTTP MCP · Issues, Projects & Cycles",
        category: .devAndObservability,
        endpointURL: "https://mcp.linear.app/mcp/readonly",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: ["read"],
        setupInstructions: "Sign in with Linear OAuth 2.1 + PKCE (dynamic client registration) or switch auth mode to Bearer Token and paste a Linear Personal API Key."
    )

    // MARK: Productivity & Design

    public static let notionHosted = MCPServerPreset(
        id: "notion-mcp",
        name: "Notion (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Pages & Databases",
        category: .productivityAndDesign,
        endpointURL: "https://mcp.notion.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Notion OAuth 2.1 + PKCE using MCP Dynamic Client Registration."
    )

    public static let atlassianHosted = MCPServerPreset(
        id: "atlassian-mcp",
        name: "Atlassian (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Jira Issues & Confluence Pages",
        category: .productivityAndDesign,
        endpointURL: "https://mcp.atlassian.com/v2/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Atlassian OAuth 2.1 + PKCE using MCP Dynamic Client Registration."
    )

    public static let slackHosted = MCPServerPreset(
        id: "slack-mcp",
        name: "Slack (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Channels & Messages",
        category: .productivityAndDesign,
        endpointURL: "https://mcp.slack.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Slack OAuth 2.1 + PKCE using MCP Dynamic Client Registration."
    )

    public static let figmaHosted = MCPServerPreset(
        id: "figma-mcp",
        name: "Figma (Hosted MCP)",
        subtitle: "Official hosted Streamable HTTP MCP · Files, Nodes & Variables",
        category: .productivityAndDesign,
        endpointURL: "https://mcp.figma.com/mcp",
        authMode: .oauthPKCE,
        readOnly: true,
        statelessMode: false,
        scopes: [],
        setupInstructions: "Sign in with Figma OAuth 2.1 + PKCE using MCP Dynamic Client Registration."
    )

    public static let betaPresets: [MCPServerPreset] = [
        .gmailPersonal,
        .googleDrivePersonal,
        .googleDocsPersonal,
        .googleSlidesPersonal,
        .googleSheetsPersonal,
        .googleCalendarPersonal,
        .vercelHosted,
        .railwayHosted,
        .cloudflareHosted,
        .netlifyHosted,
        .renderHosted,
        .stripeHosted,
        .supabaseHosted,
        .neonHosted,
        .githubHosted,
        .sentryHosted,
        .posthogHosted,
        .linearReadOnly,
        .notionHosted,
        .atlassianHosted,
        .slackHosted,
        .figmaHosted
    ]

    public static let notionQuickFillURL = "https://mcp.notion.com/mcp"
}

// MARK: - Elicitation & Tool Execution Models

/// Interaction mode for server-driven MCP elicitation or client approval checks.
public enum MCPElicitationMode: String, Codable, Sendable, Equatable {
    case form
    case url
    case clientApproval
}

/// Interactive prompt surfaced when an MCP server requests confirmation, missing fields, or URL verification,
/// or when the client-side Approval Gate pauses a write / code-execution tool.
public struct MCPElicitationRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let serverRequestID: JSONValue?
    public let connectionID: String
    public let serverName: String
    public let toolName: String
    public let mode: MCPElicitationMode
    public let message: String
    public let requestedSchema: [String: JSONValue]?
    public let url: URL?
    public let elicitationID: String?
    public let argumentsPreview: String?
    public let codePreview: String?
    public let isReadOperation: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        serverRequestID: JSONValue? = nil,
        connectionID: String,
        serverName: String,
        toolName: String,
        mode: MCPElicitationMode,
        message: String,
        requestedSchema: [String: JSONValue]? = nil,
        url: URL? = nil,
        elicitationID: String? = nil,
        argumentsPreview: String? = nil,
        codePreview: String? = nil,
        isReadOperation: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serverRequestID = serverRequestID
        self.connectionID = connectionID
        self.serverName = serverName
        self.toolName = toolName
        self.mode = mode
        self.message = message
        self.requestedSchema = requestedSchema
        self.url = url
        self.elicitationID = elicitationID
        self.argumentsPreview = argumentsPreview
        self.codePreview = codePreview
        self.isReadOperation = isReadOperation
        self.createdAt = createdAt
    }
}

/// Standard MCP elicitation response actions.
public enum MCPElicitationAction: String, Codable, Sendable, Equatable {
    case accept
    case decline
    case cancel
}

/// Client response returned to an MCP server or client Approval Gate.
public struct MCPElicitationResponse: Sendable, Equatable {
    public var action: MCPElicitationAction
    public var content: [String: JSONValue]?

    public init(action: MCPElicitationAction, content: [String: JSONValue]? = nil) {
        self.action = action
        self.content = content
    }
}

/// Result returned to the chat orchestrator after executing a tool call.
public struct MCPToolExecutionResult: Sendable, Equatable {
    public var toolCallID: String
    public var toolName: String
    public var connectionID: String
    public var outputText: String
    public var isError: Bool
    public var attachments: [ChatAttachment]
    public var elicitationAction: MCPElicitationAction?

    public init(
        toolCallID: String,
        toolName: String,
        connectionID: String,
        outputText: String,
        isError: Bool = false,
        attachments: [ChatAttachment] = [],
        elicitationAction: MCPElicitationAction? = nil
    ) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.connectionID = connectionID
        self.outputText = outputText
        self.isError = isError
        self.attachments = attachments
        self.elicitationAction = elicitationAction
    }
}

/// Errors emitted by `MCPOAuthClient`, `MCPStreamableHTTPClient`, `MCPStdioClient`, `BlenderBridgeClient`, and `MCPConnectionManager`.
public enum MCPClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint(String)
    case unauthorized(resourceMetadataURL: URL?)
    case oauthFailed(String)
    case httpError(statusCode: Int, body: String)
    case jsonRPCError(code: Int, message: String, data: JSONValue?)
    case decodingError(String)
    case toolNotFound(String)
    case readOnlyBlocked(String)
    case processError(String)
    case socketError(String)
    case vaultRequired

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "Invalid MCP endpoint URL: \(value)"
        case .unauthorized:
            return "MCP server rejected credentials (HTTP 401). Sign in or update your Bearer token."
        case .oauthFailed(let reason):
            return "OAuth authorization failed: \(reason)"
        case .httpError(let statusCode, let body):
            return body.isEmpty ? "MCP HTTP error \(statusCode)." : "MCP HTTP \(statusCode): \(body)"
        case .jsonRPCError(let code, let message, _):
            return "MCP error \(code): \(message)"
        case .decodingError(let details):
            return "Failed to decode MCP response: \(details)"
        case .toolNotFound(let name):
            return "MCP tool '\(name)' is no longer registered."
        case .readOnlyBlocked(let name):
            return "Blocked tool '\(name)' because this MCP server is configured as Read-Only."
        case .processError(let details):
            return "Stdio MCP process error: \(details)"
        case .socketError(let details):
            return "Local TCP bridge error: \(details)"
        case .vaultRequired:
            return "Unlock the Brok Bot Vault (`vault.enc`) to access or store credentials."
        }
    }
}
