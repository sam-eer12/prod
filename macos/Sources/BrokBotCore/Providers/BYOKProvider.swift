import Foundation

/// Supported Bring-Your-Own-Key (BYOK) LLM providers.
public enum BYOKProviderKind: String, Codable, CaseIterable, Identifiable, Sendable, Equatable {
    case openRouter = "openrouter"
    case gemini = "gemini"
    case claude = "claude"
    case openAI = "openai"
    case nvidiaNIM = "nvidia_nim"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .claude: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        case .nvidiaNIM: return "NVIDIA NIM"
        }
    }

    public var baseURL: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        case .claude: return URL(string: "https://api.anthropic.com/v1")!
        case .openAI: return URL(string: "https://api.openai.com/v1")!
        case .nvidiaNIM: return URL(string: "https://integrate.api.nvidia.com/v1")!
        }
    }

    public var defaultModelID: String {
        switch self {
        case .openRouter: return "anthropic/claude-sonnet-4"
        case .gemini: return "gemini-2.5-pro"
        case .claude: return "claude-sonnet-4-20250514"
        case .openAI: return "gpt-4.1"
        case .nvidiaNIM: return "meta/llama-3.3-70b-instruct"
        }
    }

    /// Suggested API key format placeholder for onboarding and settings UIs.
    public var apiKeyPlaceholder: String {
        switch self {
        case .openRouter: return "sk-or-v1-..."
        case .gemini: return "AIza..."
        case .claude: return "sk-ant-..."
        case .openAI: return "sk-..."
        case .nvidiaNIM: return "nvapi-..."
        }
    }

    /// Documentation or console URL where a user can generate an API key for this provider.
    public var keyHintURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        case .claude: return "https://console.anthropic.com/settings/keys"
        case .openAI: return "https://platform.openai.com/api-keys"
        case .nvidiaNIM: return "https://build.nvidia.com/"
        }
    }
}

/// Active BYOK provider selection and model routing configuration.
public struct BYOKConfiguration: Codable, Sendable, Equatable {
    public var provider: BYOKProviderKind
    public var modelID: String
    public var customBaseURL: URL?
    public var streamingEnabled: Bool

    public init(
        provider: BYOKProviderKind = .openRouter,
        modelID: String? = nil,
        customBaseURL: URL? = nil,
        streamingEnabled: Bool = true
    ) {
        self.provider = provider
        self.modelID = modelID ?? provider.defaultModelID
        self.customBaseURL = customBaseURL
        self.streamingEnabled = streamingEnabled
    }

    /// Resolves the effective API base URL, honoring `customBaseURL` if set.
    public var effectiveBaseURL: URL {
        customBaseURL ?? provider.baseURL
    }
}
