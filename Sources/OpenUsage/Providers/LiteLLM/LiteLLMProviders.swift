import Foundation

/// The fixed set of per-provider rows on the LiteLLM card. LiteLLM reports spend keyed by its own
/// `custom_llm_provider` value; each row claims one or more of those keys and everything unclaimed is
/// folded into `other`.
///
/// The set is deliberately fixed. A widget row's label comes from its *descriptor*, not its data, so
/// the mapper can only match a `.values` line to an already-declared descriptor by label — there is no
/// way to emit a row for whatever providers a payload happens to contain. Users choose which of these
/// rows appear (and their order/pins) in Customize like any other metric.
enum LiteLLMProviders {
    struct Row: Hashable, Sendable {
        /// Descriptor id suffix — the row id is `litellm.provider.<id>`.
        let id: String
        /// The row's display label.
        let title: String
        /// The LiteLLM `custom_llm_provider` keys this row claims. Empty for the catch-all.
        let keys: Set<String>
    }

    /// Order here is the default row order within the card.
    static let rows: [Row] = [
        Row(id: "anthropic", title: "Anthropic", keys: ["anthropic"]),
        Row(id: "openai", title: "OpenAI", keys: ["openai"]),
        Row(id: "google", title: "Google", keys: ["gemini", "vertex_ai", "vertex_ai_beta", "google", "google_ai_studio"]),
        Row(id: "azure", title: "Azure OpenAI", keys: ["azure", "azure_ai", "azure_openai"]),
        Row(id: "bedrock", title: "Amazon Bedrock", keys: ["bedrock", "bedrock_converse"]),
        Row(id: "xai", title: "xAI", keys: ["xai"]),
        Row(id: "deepseek", title: "DeepSeek", keys: ["deepseek"]),
        Row(id: "mistral", title: "Mistral", keys: ["mistral"]),
        Row(id: "groq", title: "Groq", keys: ["groq"]),
        Row(id: "openrouter", title: "OpenRouter", keys: ["openrouter"]),
        Row(id: "ollama", title: "Ollama", keys: ["ollama", "ollama_chat"]),
        Row(id: "together", title: "Together AI", keys: ["together_ai", "together"]),
        Row(id: "other", title: "Other", keys: [])
    ]

    /// The id of the row a LiteLLM provider key belongs to — `other` when nothing claims it.
    static func rowID(forProviderKey key: String) -> String {
        let lower = key.lowercased()
        return rows.first { !$0.keys.isEmpty && $0.keys.contains(lower) }?.id ?? "other"
    }
}
