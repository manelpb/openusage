import Foundation

struct LiteLLMMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
}

/// Turns LiteLLM's `/user/daily/activity` payload into the card's spend rows. LiteLLM reports spend per
/// upstream provider for each day, so each row (Today / This Month / Last 30 Days) carries a ranked
/// per-provider breakdown shown on hover — the card answers "which provider cost me what" without a
/// fixed widget row per provider.
enum LiteLLMUsageMapper {
    /// The rolling window the card shows and the client queries.
    static let windowDays = 30

    /// The hover panel's source note.
    static let providerBreakdownNote = "Spend per provider, tracked by your LiteLLM gateway."

    static func mapActivity(
        _ body: Data,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> LiteLLMMappedUsage {
        guard let root = ProviderParse.jsonObject(body) else {
            throw LiteLLMUsageError.invalidResponse
        }

        let days = parseDays(root["results"])
        let todayKey = LiteLLMUsageClient.dayKey(now, calendar: calendar)
        let monthPrefix = String(todayKey.prefix(7))
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: now) ?? now
        let windowStartKey = LiteLLMUsageClient.dayKey(windowStart, calendar: calendar)

        let month = aggregate(days.filter { $0.date.hasPrefix(monthPrefix) })

        return LiteLLMMappedUsage(lines: [
            periodLine(label: "Today", aggregate: aggregate(days.filter { $0.date == todayKey })),
            periodLine(label: "This Month", aggregate: month),
            // `yyyy-MM-dd` compares lexicographically, so a plain string bound is exact.
            periodLine(label: "Last \(windowDays) Days", aggregate: aggregate(days.filter { $0.date >= windowStartKey }))
        ] + providerRowLines(for: month))
    }

    // MARK: - Parsing

    private struct ProviderTotals {
        var spend: Double
        var tokens: Int
    }

    private struct DayRecord {
        var date: String
        var spend: Double
        var tokens: Int
        var providers: [String: ProviderTotals]
    }

    private struct PeriodTotals {
        var spend: Double
        var tokens: Int
        var providers: [String: ProviderTotals]
    }

    private static func parseDays(_ value: Any?) -> [DayRecord] {
        guard let results = value as? [Any] else { return [] }
        var days: [DayRecord] = []
        for case let entry as [String: Any] in results {
            guard let date = (entry["date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !date.isEmpty
            else { continue }

            let metrics = entry["metrics"] as? [String: Any] ?? [:]
            days.append(DayRecord(
                date: date,
                spend: max(0, ProviderParse.number(metrics["spend"]) ?? 0),
                tokens: int(metrics["total_tokens"]),
                providers: parseProviders((entry["breakdown"] as? [String: Any])?["providers"])
            ))
        }
        return days
    }

    private static func parseProviders(_ value: Any?) -> [String: ProviderTotals] {
        guard let object = value as? [String: Any] else { return [:] }
        var providers: [String: ProviderTotals] = [:]
        for (key, raw) in object {
            guard let entry = raw as? [String: Any] else { continue }
            // LiteLLM nests each provider's numbers under `metrics` (same shape as the day-level
            // `metrics`); tolerate a flat object too.
            let metrics = entry["metrics"] as? [String: Any] ?? entry
            providers[key] = ProviderTotals(
                spend: max(0, ProviderParse.number(metrics["spend"]) ?? 0),
                tokens: int(metrics["total_tokens"])
            )
        }
        return providers
    }

    private static func int(_ value: Any?) -> Int {
        guard let number = ProviderParse.number(value), number.isFinite else { return 0 }
        return Int(number.rounded())
    }

    // MARK: - Aggregation

    private static func aggregate(_ days: [DayRecord]) -> PeriodTotals {
        var totals = PeriodTotals(spend: 0, tokens: 0, providers: [:])
        for day in days {
            totals.spend += day.spend
            totals.tokens += day.tokens
            for (key, provider) in day.providers {
                var existing = totals.providers[key] ?? ProviderTotals(spend: 0, tokens: 0)
                existing.spend += provider.spend
                existing.tokens += provider.tokens
                totals.providers[key] = existing
            }
        }
        return totals
    }

    private static func periodLine(label: String, aggregate: PeriodTotals) -> MetricLine {
        .values(
            label: label,
            values: [MetricValue(number: aggregate.spend, kind: .dollars)],
            modelBreakdown: breakdown(for: aggregate)
        )
    }

    /// One row per provider that had any activity this month, carrying its month-to-date spend. LiteLLM
    /// provider keys are folded onto the fixed `LiteLLMProviders` rows, with anything unclaimed going to
    /// "Other". A row with no activity emits no line at all, so its descriptor renders "No data".
    private static func providerRowLines(for month: PeriodTotals) -> [MetricLine] {
        var spendByRow: [String: Double] = [:]
        var activeRows: Set<String> = []
        for (key, totals) in month.providers where totals.spend > 0 || totals.tokens > 0 {
            let rowID = LiteLLMProviders.rowID(forProviderKey: key)
            activeRows.insert(rowID)
            spendByRow[rowID, default: 0] += totals.spend
        }
        return LiteLLMProviders.rows.compactMap { row in
            guard activeRows.contains(row.id) else { return nil }
            return .values(label: row.title, values: [MetricValue(number: spendByRow[row.id] ?? 0, kind: .dollars)])
        }
    }

    /// A ranked per-provider breakdown for the row's hover panel, or `nil` when the period has no
    /// provider-level detail (the row then shows no detail affordance).
    private static func breakdown(for totals: PeriodTotals) -> ModelUsageBreakdown? {
        let entries = totals.providers
            .filter { $0.value.spend > 0 || $0.value.tokens > 0 }
            .map { key, value in
                ModelUsageEntry(model: displayName(key), totalTokens: value.tokens, costUSD: value.spend)
            }
            .sorted { ($0.costUSD ?? 0, $0.totalTokens) > ($1.costUSD ?? 0, $1.totalTokens) }

        guard !entries.isEmpty else { return nil }
        return ModelUsageBreakdown(
            totalTokens: totals.tokens,
            totalCostUSD: totals.spend,
            models: entries,
            sourceNote: providerBreakdownNote
        )
    }

    /// LiteLLM keys its breakdown by `custom_llm_provider` value; map the common ones to the names their
    /// own products use and title-case anything else.
    static func displayName(_ providerKey: String) -> String {
        switch providerKey.lowercased() {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "azure", "azure_ai", "azure_openai": return "Azure OpenAI"
        case "gemini", "google", "vertex_ai", "vertex_ai_beta": return "Google"
        case "bedrock", "bedrock_converse": return "Amazon Bedrock"
        case "xai": return "xAI"
        case "deepseek": return "DeepSeek"
        case "mistral": return "Mistral"
        case "groq": return "Groq"
        case "openrouter": return "OpenRouter"
        case "ollama", "ollama_chat": return "Ollama"
        case "perplexity": return "Perplexity"
        case "together_ai": return "Together AI"
        case "fireworks_ai": return "Fireworks AI"
        case "cohere", "cohere_chat": return "Cohere"
        case "meta_llama", "meta": return "Meta"
        case "litellm_proxy": return "LiteLLM"
        default:
            return providerKey
                .replacingOccurrences(of: "_", with: " ")
                .titleCased(separator: { $0 == " " }, lowercasingTail: true)
        }
    }
}
