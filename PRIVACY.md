# Privacy

AI Usage is a local, read-only macOS utility. It does not operate a server and
does not send conversation content, credentials or usage history to the project
maintainers.

## Data read locally

- Claude Code session counters under the user's selected/local Claude data.
- The existing local Claude login solely to request the user's current limits.
- Codex usage through the locally installed `codex app-server` process.

macOS may require permission to access another app's data. The user can deny or
change that access at any time. AI Usage does not modify Claude or Codex files.

## Data stored locally

- Current percentages, reset times and freshness state for immediate display.
- Daily token totals and streak state.
- A SQLite metrics index containing up to ninety days of timestamps, model
  names, numeric token counters, file offsets and hashed identifiers. It does
  not contain prompts or responses and does not retain source file paths in
  plain text.
- A security-scoped bookmark when the user explicitly selects Claude's folder.

The metrics index can be removed from
`~/Library/Caches/<bundle-id>/usage-metrics-v1.sqlite3`; AI Usage
will rebuild it from the local counters. Removing the app's container/defaults
also removes its other cached settings.

## Cost estimates

Displayed costs are API-equivalent estimates based on public per-model prices.
They are not invoices or subscription charges and are always marked with `~`.

## Network access

AI Usage uses the existing local Claude/Codex authentication flows to retrieve
usage limits. It does not send analytics or telemetry to the maintainers.
