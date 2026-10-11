# LiteLLM

Tracks what each upstream provider cost, as logged by a self-hosted [LiteLLM](https://docs.litellm.ai)
gateway. Use this when you route model calls (agents, Cursor, Codex, Claude Code, custom apps) through
LiteLLM and want one place to see the gateway's spend broken down by provider.

This is API spend recorded by the gateway — it is not your Claude/Codex subscription quota, and it is
separate from the app's own local spend tiles.

## What it tracks

| Metric | Meaning |
|---|---|
| Today | Gateway spend so far today |
| This Month | Gateway spend so far this calendar month |
| Last 30 Days | Gateway spend over the rolling 30-day window |
| Anthropic / OpenAI / Google / … / Other | Month-to-date spend for that upstream provider |

The per-provider rows cover the common LiteLLM upstreams — Anthropic, OpenAI, Google, Azure OpenAI,
Amazon Bedrock, xAI, DeepSeek, Mistral, Groq, OpenRouter, Ollama, and Together AI — with anything else
folded into **Other**. A provider with no activity this month reads **No data**. The row set is fixed
(a row's name comes from its descriptor, not the data), so turn off the providers you don't route to in
**Customize**; like any metric they can be hidden, reordered, and pinned.

Hover any of the three period rows to see the same spend split **per upstream provider**, ranked with each
provider's cost, token count, and share.

Up to **two** LiteLLM rows can be pinned to the menu bar; **Today** and **This Month** are pinned by
default. Swap either for a per-provider row in Customize if you'd rather watch one provider in the strip.

## Where credentials come from

LiteLLM has no companion app, so you supply the gateway URL and a key that is allowed to read spend.
A normal inference-only virtual key is refused (HTTP 403) by the spend endpoints. Use either:

- a **Proxy Admin Viewer** key (`proxy_admin_viewer`) for a whole-gateway view, or
- that user's **internal-user key**, which can read its own activity.

Create the config file `~/.config/openusage/litellm.json`:

```json
{
  "baseUrl": "https://litellm.example.com",
  "apiKey": "sk-...",
  "userId": "optional-user-id"
}
```

`baseUrl` is the gateway root (no `/v1` suffix). `userId` is optional: `/user/daily/activity` is
per-user, so an admin key must name the user whose activity to read.

You can also provide the values through the environment (the config file wins when both are set):

| Value | Environment variables |
|---|---|
| Gateway URL | `LITELLM_BASE_URL`, `LITELLM_URL` |
| Key | `LITELLM_API_KEY`, `LITELLM_MASTER_KEY` |
| User (optional) | `LITELLM_USER_ID` |

On launch the app reads your login shell's environment, so a variable exported in your shell profile
is picked up even when the app starts from Finder or the Dock.

## Troubleshooting

- **"No LiteLLM gateway configured"** — add `baseUrl` and `apiKey` to `~/.config/openusage/litellm.json` (or the environment), then refresh.
- **"LiteLLM key rejected"** — the key is a 401/403: it's wrong, or it isn't allowed to read spend. Use an admin-viewer or internal-user key.
- **Spend rows read "No data"** — the gateway returned no activity for the period, or the endpoint's date range is empty.

## Under the hood

One request against the gateway:

- `GET {baseUrl}/user/daily/activity?start_date=…&end_date=…` (Bearer auth) — per-day spend, token
  counts, and request counts, each with a `breakdown` by model, provider, and API key.

The card queries from the earlier of the current month and the rolling 30-day window, then aggregates
the daily rows into the three periods locally. Provider names come from LiteLLM's breakdown key
(`custom_llm_provider`). Costs are LiteLLM's own tracked spend, priced from its model tables, so they
can differ slightly from a provider's invoice.
