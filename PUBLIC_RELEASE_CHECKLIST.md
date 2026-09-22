# Public release checklist

AI Usage is intended to become a standalone, open-source macOS project. Do not
make the current monorepo public as a shortcut: its unrelated history, workflow
logs and configuration must not become part of the release.

## 1. Lightweight runtime

- [x] Persist local counters in SQLite instead of rescanning every JSONL.
- [x] Read only appended bytes and rebuild only truncated or replaced files.
- [x] Throttle file metadata checks to fifteen minutes.
- [x] Test unchanged, appended and truncated logs.
- [x] Benchmark a cold 818 MB import: bounded streaming memory, about two
  minutes once, followed by only the newly appended bytes.
- [x] Measure the installed notarized Release for one hour: 0.271% average CPU
  (0% median), 59.36 MB average RSS (56.75 MB median), and no sustained disk
  reads. See `PERFORMANCE.md` for the reproducible report and interpretation.
- [x] Compare the 90-day incremental index against a clean full import over
  1.47 GB of real local history; weekly totals and daily series match exactly.

## 2. Signed permission smoke test

- [x] Add a non-interactive provider report to the Release app.
- [x] Add `Scripts/smoke-test-signed-app.sh` with three relaunches.
- [x] Install an Apple Development or Developer ID Application certificate.
- [x] Run once after onboarding on the development Mac (three launches passed).
- [ ] Run against the notarized ZIP on a clean macOS user or separate Mac.
- [x] Upgrade over a previous version and repeat without resetting TCC.

## 3. Standalone repository

- [x] Validate a standalone export from `apps/macos` without importing unrelated
  monorepo history; its tests and unsigned Release build pass independently.
- [x] Create the public GitHub repository from the validated export:
  `carlosrebato/ai-usage-mac`.
- [x] Run secret scanning over the source tree; the new repository starts with
  no inherited history.
- [x] Replace personal Team ID, bundle IDs and App Group with documented build
  settings for forks; keep official values only in the protected release job.
- [x] Include MIT license, contributing guide, security policy and privacy note.
- [x] Add issue and pull-request templates plus a code of conduct.
- [x] Enable branch protection, required CI, Dependabot, secret scanning, push
  protection and CodeQL (verified in the authenticated repository settings on
  2026-09-22; `main` requires the up-to-date `test-and-build` check).

## 4. Distribution

- [x] Create a Developer ID Application certificate and resolve the required
  signing assets with Xcode automatic signing.
- [x] Archive a universal `arm64 + x86_64` Release with hardened runtime.
- [x] Verify that `get-task-allow` is absent and validate nested signatures.
- [x] Submit to Apple's notary service, staple the ticket and pass `spctl`
  assessment.
- [ ] Test the downloaded artifact with Gatekeeper on a clean Mac.
- [x] Publish a GitHub Release containing the notarized ZIP, SHA-256 checksum and
  changelog.
- [x] Keep signing/notarization credentials exclusively in the local Keychain
  while releases are manual. The empty GitHub `release` environment is limited
  to protected branches, requires approval from `carlosrebato`, and does not
  allow administrator bypass. Never expose secrets to pull-request workflows.
- [x] Add signed automatic updates with Sparkle plus a manual “Check for Updates”.
- [x] Publish `appcast.xml` with every signed and notarized GitHub Release
  (verified on `main` for `v0.1.2-beta.1`).

## 5. Product readiness

- [x] Increase small muted-text contrast to WCAG AA (minimum measured ratio
  4.81:1 on the lightest tinted application surface).
- [x] Add Help, Privacy and Report an Issue links.
- [x] Add local diagnostic export without prompts, responses or credentials.
- [x] Document supported Claude/Codex versions and the pricing-data update policy.
- [x] Choose the first public version (`0.1.0-beta.1`) and maintain a changelog.

## 6. Release gate

Run `Scripts/release-readiness.sh` against the exact app extracted from the
downloadable ZIP. A client launch is blocked unless the script passes all unit
and state-transition tests, bundle validation, Developer ID signature checks,
the no-`get-task-allow` invariant, universal architectures, stapled
notarization, Gatekeeper and three signed relaunch smoke tests.
