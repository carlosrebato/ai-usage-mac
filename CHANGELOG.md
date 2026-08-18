# Changelog

All notable changes to AI Usage for Mac are documented here.

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
