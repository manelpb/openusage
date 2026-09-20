# Ollama Reset Times & Run-out Projection — Design

**Goal:** Give Ollama's Session and Weekly meters real reset times, so the meter countdown and the
derived per-provider **Run-out** (projection) row render — without changing where the usage
*values* come from.

**Status:** Approved design. Implementation plan follows in a separate document.

---

## Background

Ollama's Session/Weekly rows show percentages but no countdown and no Run-out row. The reason is
structural, not a UI gap:

- `GET https://ollama.com/api/usage` returns only `limits.session`/`limits.weekly` as
  `{ usage: 0..1, models: [...] }` plus an `activity` block. **No reset timestamp** exists anywhere in
  the payload or response headers. Verified live against the account (plan `pro`, session/weekly model)
  and corroborated by upstream ollama/ollama#15663 and fgrehm/pi-ollama-cloud#42.
- The current mapper (`Sources/OpenUsage/Providers/Ollama/OllamaUsageMapper.swift`) therefore emits
  `.progress` with neither `resetsAt` nor `periodDurationMs` — deliberately, because a period without a
  reset date renders as a static "Resets in 5h" that never counts down.
- `PaceProjectionSummary.select` (`Sources/OpenUsage/Support/PaceProjectionSummary.swift:22`) keeps only
  meters with `resetsAt != nil` and `periodDurationMs > 0`, so Ollama's meters can never qualify for the
  Run-out row.

The reset data *does* exist on the authenticated settings page (`https://ollama.com/settings`), which is
what CodexBar scrapes (via browser cookies + `data-time` attributes). This fork previously had a working
web-based Ollama provider that read those resets; it was removed when upstream's signed-API provider was
merged in.

## What was removed (git history)

| Commit | What it added |
|---|---|
| `919fe6eb` | Ollama provider that read a session cookie from env/Keychain/browser cookie DBs and scraped the settings page. |
| `dd127949` | In-app WKWebView sign-in + hidden background refresher; parsed the JS-rendered DOM and extracted reset times from "Sessions resume in …" / "Resets in …". |
| `2bc8660e` | Extracted generic `WebPageRefresher` (WKWebView, cookie injection, `document.body.innerText`). |

Upstream's signed-API provider (`3814d24f`) replaced it via merges `590e77d4`/`053d1983`. Today the tree
has no `WebPageRefresher`, no `WKWebView`, no `supportsInAppSignIn`, and no login view. The old code
targeted the NextAuth cookie `__Secure-session`, which is stale — the page is now WorkOS AuthKit
(`wos-session`).

## Decisions

1. **One provider, not two.** Restore reset-aware behavior inside the existing `ollama` provider rather
   than adding a second Ollama card. Avoids duplicate credentials/enablement and a confusing UI.
2. **In-app WKWebView sign-in**, not browser-cookie import. Self-contained, no Full Disk Access, no
   brittle browser-specific cookie decryption.
3. **API for values, web only for resets.** Keep the signed `/api/usage` call as the source of Session/
   Weekly percentages; the web session supplies only `resetsAt` (+ `periodDurationMs`). Fully additive —
   with no web session, behavior is exactly today's.
4. **Prefer the `data-time` attribute, regex as fallback.** Read the ISO attribute on the reset elements
   (what CodexBar does); fall back to the old "Resets in …" / "Sessions resume in …" text regexes if the
   attribute is gone.
5. **Probe-gated refresh path.** The authenticated page's rendering is not yet confirmed. A one-time
   probe decides between:
   - **A — URLSession + HTML:** fetch the settings HTML with the session cookies and parse `data-time`
     from the markup (CodexBar's approach; cheap, no WebKit on the hot path).
   - **B — hidden WKWebView:** load the page and `evaluateJavaScript` the reset elements (works
     regardless of rendering, but heavier).
6. **Run-out row defaults** (confirmed with owner): enabled, Always Visible, unpinned, placed after the
   Session/Weekly meters.
7. **Reuse the removed components** where possible, keeping names close to the originals to ease upstream
   rebases.

## Architecture

```
OllamaProvider.refresh()
  ├─ signed /api/usage  ─────────────► Session/Weekly values (unchanged)
  ├─ if web session present:
  │    OllamaResetSource.resets()  ──► (sessionResetsAt, weeklyResetsAt)
  │         ▲                          │
  │    cache in UserDefaults ◄─────────┘  (reuse while a cached reset is in the future)
  └─ build .progress lines with resetsAt + periodDurationMs (5h / 7d)
     + .projectionSummary(provider:) row derives from those meters
```

**Components**

- `WebPageRefresher` (restored, generic): WKWebView loader that returns rendered page text/DOM given a
  URL and cookies. Used for sign-in; reused by reset-source **B** if chosen.
- Sign-in sheet + controller (restored, adapted): captures the full `ollama.com` cookie set (not a single
  named cookie) and persists the session via a `WKWebsiteDataStore` so it survives app launches.
- `OllamaResetSource` (new): protocol `resets() async -> OllamaResets?` with two conformances
  (HTTP/URLSession and WKWebView). Injected into `OllamaProvider` so tests use a fake and no WebKit.
- `OllamaResetParser` (new, pure): parses reset instants from HTML or rendered text. Prefers `data-time`;
  falls back to the removed code's regexes. Unit-tested against fixtures.
- `OllamaProvider` (modified): keeps the signed-API path for values; layers resets onto the two
  `.progress` lines; unchanged when no session exists.
- `DefaultLayout` / descriptors (modified): add `ollama.projection` (`.projectionSummary`), enabled,
  Always Visible, unpinned.

**Session storage:** an app-private persistent `WKWebsiteDataStore`. Cookies are read from the store for
HTTP fetches; no cookie name is hardcoded.

## Data flow

1. `refresh()` performs the existing signed calls and builds the Session/Weekly/Last-4-Weeks lines.
2. If a web session exists, obtain resets: reuse a cached value while its instant is in the future;
   otherwise fetch the page and parse.
3. Rebuild the two `.progress` lines with `resetsAt` and `periodDurationMs` (session 5h, weekly 7d).
   `PaceProjectionSummary` then picks the most at-risk meter and the Run-out row renders.
4. Cache parsed resets in `UserDefaults` (per provider) so restarts and most refreshes need no page load.

## Error handling

- The web path must never blank the meters: a page/parse failure logs loudly and yields lines **without**
  resets; the API values still render.
- A redirect to `signin.ollama.com` means the session expired → surface a "Sign in again" hint on the
  Ollama header and keep serving API-only values.
- No silent fallbacks: parse failures and HTTP failures are logged with enough context to diagnose a DOM
  change.

## Testing

- Pure unit tests for `OllamaResetParser` against saved fixtures: `data-time` present; attribute absent →
  regex fallback; neither present → `nil`; malformed dates → `nil`.
- Line-building tests: with resets → `resetsAt`/`periodDurationMs` set and projection qualifies; without →
  unchanged from today.
- `OllamaProvider` tests with an injected fake `OllamaResetSource`: session present/absent, stale cached
  reset, expired session. No WKWebView in the test suite.
- The live-page probe is a manual/dev step, not a unit test.

## Merge posture

Changes are additive within the existing provider plus restored generic components. Because upstream owns
`OllamaProvider.swift`, future upstream Ollama changes will conflict; keep diffs small and names close to
the removed versions to ease rebases.

## Out of scope

- Browser-cookie import (rejected above).
- Changing Ollama's value source or its opt-in `hasLocalCredentials() == false` behavior.
- Any projection for a monthly-credits quota model (this account is on session/weekly; the monthly model,
  if it arrives, would need its own design).
