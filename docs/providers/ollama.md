# Ollama

Tracks [Ollama Cloud](https://ollama.com) plan usage — the Session and Weekly limits Ollama shows on its
own settings page.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour window usage (percentage of your plan's allowance) |
| Weekly | 7-day window usage (percentage of your plan's allowance) |
| Monthly | Monthly usage (percentage of your plan's allowance), when reported for your account |
| Last 4 Weeks | Charges beyond your plan over the last four weeks. $0.00 on a subscription; real amounts for pay-as-you-go and API-key usage |

Your plan (Free, Pro, Max) is shown beside the provider name. If Ollama can't tell OpenUsage which plan
you're on, the badge is left off and the card explains why — the meters keep working either way.

Session, Weekly, and Monthly are always visible; Session and Weekly start pinned to the menu bar.
Monthly starts unpinned and follows Weekly. The derived **Run-out** row is also always visible and
unpinned. Last 4 Weeks sits behind the provider's caret — you can move any of them in **Customize**. A
$0.00 on that row means no extra charges, not an idle month: usage inside your plan's allowance is counted
by the limit meters.

Session and Weekly come from your authenticated [ollama.com settings page](https://ollama.com/settings),
which is the only place Ollama still reports them — its signed `/api/usage` endpoint stopped returning the
limit percentages in late 2026. Reading that page needs the web session, so **Sign In** on the Ollama header
is required for these meters. The page carries the reset instants too, so Session and Weekly show a
countdown, and the derived **Run-out** row projects when you'd hit the limit. Local models don't count
toward these limits; only cloud models do.

**Monthly** and **Last 4 Weeks** came from the signed `/api/usage` endpoint, which no longer reports
either, so those rows read **No data** until Ollama restores them.

## Where credentials come from

Nothing to paste. Ollama creates a signing key at `~/.ollama/id_ed25519` the first time it runs, and
`ollama signin` links that key to your ollama.com account. OpenUsage reads the key, signs each request
with it exactly as the Ollama CLI does, and never sends the key anywhere — only the signature goes out.

Because that key exists whether or not you've signed in, OpenUsage can tell only that Ollama is
installed — not that Ollama Cloud is set up. So Ollama never switches itself on, even when the key is
there: if you use Ollama for local models alone, it stays out of your way instead of showing you a
sign-in warning for a product you don't use. Turn it on in **Customize** when you want it.

## Setup

1. Install [Ollama](https://ollama.com/download) and create an account for a [cloud plan](https://ollama.com/pricing),
   including Free.
2. Sign in:

```bash
ollama signin
```

3. Turn **Ollama** on in **Customize** — unlike most providers, it never enables itself (see above).
4. Optional, for reset countdowns: click **Sign In** on the Ollama header and log in to ollama.com. This
   stores an ollama.com session cookie in your Keychain (no password), used only to read the reset times on
   your settings page.

Your Session and Weekly meters appear on the next refresh once you're signed in — Free cloud accounts
report them too. Signing in also brings the reset countdown and the **Run-out** row.

## Under the hood

Ollama.com endpoints, authenticated with a signature from your local Ollama key (and, for the settings
page, your web session cookie):

- `GET https://ollama.com/settings` — after you **Sign In**: the Session/Weekly percentages and their
  reset instants (`data-time`). This is the source for both meters, and it's cached until a reset passes.
  If ollama.com rejects the stored session, the Sign In button returns and the meters clear until you sign
  in again.
- `GET https://ollama.com/api/usage` — best-effort. It used to carry the meters; Ollama now returns
  request-count activity instead, so OpenUsage only uses it when it still carries a `limits` block.
- `POST https://ollama.com/api/me` — the plan name (best-effort; a failure here doesn't blank the meters).

Each request carries an `Authorization` header of `<public key>:<signature>`, signing the string
`<METHOD>,<request-uri>` where the URI includes a `ts` unix-seconds parameter — the same scheme the
Ollama CLI uses, so a captured header can't be replayed later.

Both endpoints are undocumented, so OpenUsage reads them defensively: a signed `usage` is a fraction
(`0.349` → 34.9%) and `cost` is a decimal string, while the settings page reports the percentage directly.
A window that isn't reported is omitted and shows "No data" if its dashboard row is enabled, rather than
being shown as zero usage.

## Troubleshooting

- **"No Ollama key found"** — Ollama has never run on this Mac. [Install it](https://ollama.com/download)
  and run `ollama signin`.
- **"Not signed in to Ollama Cloud"** — Ollama is installed but the key isn't linked to an account.
  Run `ollama signin`.
- **"Couldn't read ~/.ollama/id_ed25519"** — the key file exists but isn't readable. Check its
  permissions (it should be owned by you, mode `600`).
- **Session/Weekly show "No data", or no reset countdown and Run-out is "No data"** — you're not signed
  in to ollama.com in the app, or the stored session expired. Click **Sign In** on the Ollama header; these
  meters are read from your settings page, so they need that session.
- **"Couldn't read your Ollama plan"** (an amber notice by the name) — the plan badge is missing because
  Ollama either didn't answer that request or answered with something OpenUsage couldn't read. Your
  meters are unaffected and still current; the badge comes back on its own once Ollama answers normally.
- **Monthly / Last 4 Weeks show "No data"** — Ollama's signed API no longer reports those, so they stay
  empty until it does again.
- **Meters show "No usage data"** — you're signed in, but the settings page reported no limits for the
  account yet. Check your usage at [ollama.com/settings](https://ollama.com/settings).
