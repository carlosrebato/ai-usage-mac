# Changelog

All notable changes to AI Usage for Mac are documented here.

## 0.1.4-rc.2 — 2026-09-25

- Keep automatic updates on the stable channel by default, with an explicit
  beta opt-in in Settings → Updates for testers.
- Separate prereleases from stable builds in the signed Sparkle appcast.

## 0.1.4-rc.1 — 2026-09-25

- Show assistants that have never been connected without a warning dot; keep
  actual connection failures distinct and localize the sign-in prompt.
- Prepare a signed, provider-specific safety policy for future direct-endpoint
  incidents. The initial published policy disables neither provider.

## 0.1.3-beta.3 — 2026-09-24

- Explain the weekly API-equivalent cost on hover using the approved copy,
  without resizing the panel or adding an info button. Show N/A when no public
  price or model breakdown can support an estimate.
- Add public standard API rates for GPT-6 Astra, Sol and Luna; keep unknown
  Codex model aliases unpriced instead of guessing their cost.
- Clarify that the displayed estimate covers the current weekly period.

## 0.1.3-beta.2 — 2026-09-22

- Keep local token totals and estimated cost available while a connected
  provider is temporarily rate limited and displaying saved quota data.
- Keep the cost and token fields visible when local history is unavailable
  instead of silently removing them from the dashboard.
- Offer a clear read-only token-history recovery action for both Claude and
  Codex when their local folder permission is missing or no longer usable.
- Recover stale readings when the menu opens after a long sleep or provider
  throttle, without leaving a long-running process trapped behind a second
  in-memory cooldown.
- Reduce automatic polling pressure; treat old live readings as saved data and
  stop showing expired reset times as "0m".
- Explain an empty seven-day chart instead of implying zero usage when no
  verified data can be shown.

## 0.1.3-beta.1 — 2026-09-22

- Centralize Claude and Codex connection flows so every screen presents the
  same atomic provider state.
- Prevent reconnection cancellation and delayed OAuth propagation from leaving
  stale errors, false connected states or crashes.
- Stop disconnected providers from contributing local metrics or a synthetic
  current-day chart point.
- Preserve the newest metrics candidate when refreshes overlap.
- Restore concrete Claude and Codex plan names and accept Claude reset times
  with fractional seconds or numeric Unix timestamps.
- Keep providers visibly connected during a temporary rate limit when a saved
  reading is available, preserving plan names, counters and reset timers.
- Distinguish saved or stale readings in orange across the menu bar, dashboard,
  Settings, assistant management, detached panel, widget and iOS app; yellow is
  now reserved for elevated quota consumption.
- Add privacy-safe diagnostic export, release-readiness checks and three-launch
  signed smoke tests.
- Raise muted text contrast to WCAG AA and add Help, Privacy and issue links.
- Verify a 90-day incremental index against a clean rebuild over 1.47 GB of
  local JSONL history.

## 0.1.1-beta.4 — 2026-08-18

- Replace the Terminal-based Claude Code login with a native browser OAuth flow
  using PKCE and an automatic localhost callback.
- Store the resulting Claude token in AI Usage's own Keychain item; the app
  never receives the user's password and no code needs to be copied or pasted.
- Ship the signed app with its explicit Keychain access group and verify a real
  write/read/delete cycle before a release can pass the signed smoke test.
- Keep existing local Claude Code and Claude Desktop sessions as fallbacks.

## 0.1.1-beta.3 — 2026-08-18

- Replace the misleading Claude Desktop launch action with an explicit Claude
  Code login command that is copied before opening Terminal.
- Refresh connection state automatically when the user returns to AI Usage.
- Remove the transparent strip below onboarding and assistant management
  windows by filling the full content height with an opaque background.
- Package release ZIPs without AppleDouble metadata and verify the conventionally
  extracted app with codesign, Gatekeeper and the stapled notarization ticket.

## 0.1.1-beta.2 — 2026-08-18

- Fix repeated macOS “data from other apps” prompts by shipping the main app
  with App Sandbox enabled and preserving the stable App Group identity.
- Connect Claude Code through the user-selected `~/.claude` folder instead of
  requiring access to Claude Desktop's `Claude Safe Storage` keychain item.
- Serialize the legacy Claude Desktop keychain fallback to prevent duplicate
  permission dialogs during overlapping refreshes.
- Reject signed release builds that omit the App Sandbox entitlement.

## 0.1.0-beta.1 — 2026-08-13

First public beta.

- Native macOS menu bar dashboard for Claude Code and OpenAI Codex.
- Session and weekly quota percentages with reset countdowns.
- Local token history, seven-day chart, streak and estimated weekly cost.
- English and Spanish interface with persistent settings.
- Read-only onboarding for local Claude and Codex connections.
- Incremental SQLite index that reads only newly appended session data.
- Universal Apple Silicon and Intel build, signed with Developer ID and
  notarized by Apple.
- Stable bundle identity so macOS permissions persist across updates.
