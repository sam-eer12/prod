package org.brokbot.android.core.providers

/**
 * Supported Bring-Your-Own-Key (BYOK) LLM inference providers.
 */
enum class BYOKProvider(
    val displayName: String,
    val defaultModel: String,
    val baseUrl: String
) {
    OPEN_ROUTER(
        displayName = "OpenRouter",
        defaultModel = "anthropic/claude-sonnet-4",
        baseUrl = "https://openrouter.ai/api/v1"
    ),
    GEMINI(
        displayName = "Google Gemini",
        defaultModel = "gemini-2.5-pro",
        baseUrl = "https://generativelanguage.googleapis.com/v1beta"
    ),
    CLAUDE(
        displayName = "Anthropic Claude",
        defaultModel = "claude-sonnet-4-20250514",
        baseUrl = "https://api.anthropic.com/v1"
    ),
    OPENAI(
        displayName = "OpenAI",
        defaultModel = "gpt-4.1",
        baseUrl = "https://api.openai.com/v1"
    ),
    NVIDIA_NIM(
        displayName = "NVIDIA NIM",
        defaultModel = "meta/llama-3.3-70b-instruct",
        baseUrl = "https://integrate.api.nvidia.com/v1"
    )
}

/**
 * Active BYOK provider selection and masked credential metadata.
 */
data class BYOKProviderConfig(
    val selectedProvider: BYOKProvider = BYOKProvider.OPEN_ROUTER,
    val selectedModel: String = selectedProvider.defaultModel,
    val isVaultBackedKeyConfigured: Boolean = false
)
