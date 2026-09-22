# Privacy

AI Usage is a local-first Mac and iOS utility. It does not operate an account
server and does not send conversation content, credentials or usage history to
the project maintainers.

## Data read

- Current usage percentages and reset times returned by Claude or Codex after
  the user signs in independently on that device.
- On Mac only, optional local numeric counters for token, activity and
  API-equivalent cost history. Local credential files are excluded.

Local filesystem access is read-only. Claude and Codex are configured
separately; the user may enable either one or both.

## Data stored locally

- Current percentages, reset times and freshness state.
- Daily token totals and streak state on Mac.
- A SQLite metrics index containing up to ninety days of timestamps, model
  names, numeric token counters, file offsets and hashed identifiers. It does
  not contain prompts, responses or source paths in plain text.
- Security-scoped bookmarks for folders the Mac user explicitly selects.
- OAuth access and refresh tokens in a non-synchronizable Data Protection
  Keychain item marked `AfterFirstUnlockThisDeviceOnly`.

## Network access

AI Usage uses its own per-device Claude/Codex authorization to retrieve current
limits directly from the corresponding provider endpoint. Credentials are sent
only to that provider. No token, email, account ID, prompt, response, filesystem
path, analytics event or diagnostic is sent to the maintainers.

Claude requests only the profile scope. Codex receives the fixed OpenID,
profile, email, offline-access and connector scopes of the public Codex client;
AI Usage calls only the usage endpoint. These endpoints are not documented as
third-party APIs. AI Usage is independent and not affiliated with Anthropic or
OpenAI.

The App Review demo uses synthetic values and does not contact a provider.

## Cost estimates

Displayed costs are API-equivalent estimates based on public per-model prices.
They are not invoices or subscription charges and are always marked with `~`.
