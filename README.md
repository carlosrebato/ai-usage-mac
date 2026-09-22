# AI Usage — Claude Code & Codex Usage Tracker for Mac and iPhone

[![CI](https://github.com/carlosrebato/ai-usage-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/carlosrebato/ai-usage-mac/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/carlosrebato/ai-usage-mac?include_prereleases)](https://github.com/carlosrebato/ai-usage-mac/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

AI Usage is an independent, local-first Mac and iPhone app for tracking Claude
Code and OpenAI Codex usage limits, reset times, tokens and estimated cost. It
reads local counters in read-only mode and never sends conversation content or
credentials to the project maintainers.

## Install

Download the latest notarized macOS ZIP from
[GitHub Releases](https://github.com/carlosrebato/ai-usage-mac/releases), unzip it
and move **AI Usage.app** to Applications. The current release is a public beta;
please report reproducible issues without attaching credentials or conversation
logs.

## Requirements

- macOS 15 or iOS 18 (the iOS target is currently an App Review viability spike)
- A Claude or ChatGPT account. Each device signs in independently through the
  provider; AI Usage never imports a Claude Code, Codex CLI or desktop token.

You can enable Claude, Codex or both. The Claude and Codex desktop apps are not
required for live limits: AI Usage signs in to each provider independently.
Their command-line tools are optional and are used only when you choose to add
local token, activity and estimated-cost history on Mac.

### Provider compatibility and pricing

The supported configuration is macOS 15 or later with a current Claude or
ChatGPT web account. AI Usage does not depend on a particular Claude Code or
Codex CLI version for authentication or live limits. Optional local-history
imports are tested against the current stable CLI formats at release time;
unknown JSON fields are ignored, and an incompatible local format must degrade
to live limits instead of changing connection state.

Claude and Codex limit endpoints are not documented for third-party clients and
can change without notice. Every release is smoke-tested against both providers;
a provider can be disabled independently if compatibility breaks. Supported
capabilities and the release-blocking checks are documented in
[OAUTH_CAPABILITIES.md](OAUTH_CAPABILITIES.md).

Cost figures are estimates, never billing data. Model prices are versioned in
source, reviewed against the providers' public pricing pages before each release,
and updated in a normal app release when pricing changes. Unknown models remain
in token totals but do not inherit a guessed price. Users should use Anthropic
or OpenAI billing records for financial decisions.

### Requirements for contributors

- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build and run

The generated Xcode project is checked in. Regenerate it whenever `project.yml`
changes:

```sh
xcodegen generate
open AIUsage.xcodeproj
```

Run the `AIUsageMac` scheme from Xcode when testing access to Claude's local
data. `swift run AIUsageMac` uses an ad-hoc signature that changes after a
rebuild, so macOS cannot reliably reuse TCC or Keychain permissions for it.

For a stable signed development build, register your own bundle IDs and App
Group in Apple Developer, then run:

```sh
AI_USAGE_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
AI_USAGE_APP_BUNDLE_ID=com.example.aiusage \
AI_USAGE_APP_GROUP=group.com.example.aiusage \
Scripts/build-signed-debug.sh
```

The script builds outside synced folders, validates the signature, bundle ID
and App Group, and avoids Finder metadata that can invalidate `codesign`. Install
the app you use regularly at `/Applications/AI Usage.app`.

The public project defaults to `com.example.aiusage` and
`group.com.example.aiusage`. Official releases override the build settings
`AI_USAGE_APP_BUNDLE_ID`, `AI_USAGE_WIDGET_BUNDLE_ID` and
`AI_USAGE_APP_GROUP`; certificates, provisioning profiles and Apple credentials
are never stored in the repository.

## How it works

AI Usage opens a native dashboard and adds usage indicators to the menu bar.
Claude and Codex sign in through browser OAuth with PKCE, random state and a
different refresh-token family on every device. Tokens are stored in a
non-synchronizable `ThisDeviceOnly` Keychain item. AI Usage never receives the
user's password or reads another app's credential files. It then requests the
current limits directly from provider endpoints. Those usage endpoints are not
documented as third-party APIs and may change without notice.
Authentication is sent only to the corresponding provider, is never sent to the
project maintainers and is never stored in the app's cache.

- `AIUsageCore`: models, polling policy and shared cache.
- `AIUsageDesignSystem`: visual tokens and reusable components.
- `AIUsageProviderServices`: per-device OAuth, Keychain and direct adapters.
- `AIUsageMacServices`: Mac-only fallbacks, local metrics and app state.
- `AIUsageMac`: macOS window and menu bar app.
- `AIUsageWidgets`: WidgetKit extension that reads the latest shared snapshot.

The widget does not access credentials or run local tools. The main app shares
only usage percentages, reset dates and freshness status through the configured
App Group.

Token totals, the chart and estimated cost are calculated with a local SQLite
index. The first read imports existing history; later passes check metadata every
fifteen minutes and read only bytes appended to recent JSONL files. The index
keeps at most ninety days of counters, models, dates, offsets and hashed IDs. It
never stores prompts or responses.

Delete `~/Library/Caches/<bundle-id>/usage-metrics-v1.sqlite3` to rebuild the
index. On an 818 MB local history, the measured cold import took about two
minutes; the immediate incremental pass read only 213 KB written while the test
was running.

Optional access to `~/.claude` and `~/.codex` is read-only and is used only for
local token/activity/cost history on Mac. It is never used for authentication.
For limit stability, Mac can fall back to Claude's numeric statusline artifact
or the documented `codex app-server` rate-limit method; neither exposes a token
to AI Usage. iPhone always updates directly and does not depend on the Mac.

AI Usage is not affiliated with, endorsed by or sponsored by Anthropic or
OpenAI. See [OAUTH_CAPABILITIES.md](OAUTH_CAPABILITIES.md) for exact scopes and
[APP_REVIEW.md](APP_REVIEW.md) for the blocking distribution gate.

At launch, each provider is classified as connected, awaiting permission,
awaiting login, not installed or temporarily unavailable. Setup controls are
shown only while there is something to resolve. All connector operations have
bounded timeouts and terminate local helper processes when cancelled.

## Verify

Run the unit suite:

```sh
swift test
```

The real local-provider checks are opt-in:

```sh
RUN_CODEX_INTEGRATION_TEST=1 swift test --filter readsTheLocalCodexSession
RUN_CLAUDE_INTEGRATION_TEST=1 swift test --filter probesTheLocalClaudeLogin
```

Permission persistence must be tested with a stably signed bundle, not SwiftPM:

```sh
Scripts/smoke-test-signed-app.sh "/Applications/AI Usage.app" 3
```

To reproduce the unsigned diagnostic bundle built by CI:

```sh
Scripts/build-unsigned-artifact.sh
```

That ZIP is for bundle validation only; do not distribute it to users. Developer
ID signing and notarization are documented in [DISTRIBUTION.md](DISTRIBUTION.md).
The notarized Release performance baseline and reproduction command are in
[PERFORMANCE.md](PERFORMANCE.md).
See [PRIVACY.md](PRIVACY.md) for the local data model and
[PUBLIC_RELEASE_CHECKLIST.md](PUBLIC_RELEASE_CHECKLIST.md) for release readiness,
and [CHANGELOG.md](CHANGELOG.md) for version history.
