# App Review viability spike

The `AIUsageIOS` target is the deliberately small v0.1 submission candidate.
It includes direct Claude/Codex sign-in, current session and weekly percentages,
reset times, freshness, manual refresh, sign-out and an explicit synthetic demo.

It intentionally excludes StoreKit, CloudKit, prediction, alerts, advanced
charts and widgets. Review notes must state:

- AI Usage is an independent, non-affiliated usage viewer.
- Authentication occurs on-device against each provider with PKCE.
- Credentials never reach project infrastructure or another device.
- The ellipsis menu enables “App Review demo” without an account.
- The usage endpoints are read-only but are not documented third-party APIs.

If rejected, reply once with the technical explanation and public App Store
precedents. If an appeal requires written provider authorization, stop the
affected integration rather than hiding it in a later build.
