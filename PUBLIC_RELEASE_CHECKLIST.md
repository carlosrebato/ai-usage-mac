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
- [ ] Compare the index against a clean full import on a large fixture.

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
- [ ] Enable branch protection, required CI, Dependabot, secret scanning, push
  protection and CodeQL.

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
- [ ] Protect signing/notarization secrets in a GitHub environment with manual
  approval; never expose them to pull-request workflows.
- [x] Add signed automatic updates with Sparkle plus a manual “Check for Updates”.
- [ ] Publish `appcast.xml` with every signed and notarized GitHub Release.

## 5. Product readiness

- [ ] Increase small muted-text contrast to WCAG AA.
- [ ] Add Help, Privacy and Report an Issue links.
- [ ] Add local diagnostic export without prompts, responses or credentials.
- [ ] Document supported Claude/Codex versions and the pricing-data update policy.
- [x] Choose the first public version (`0.1.0-beta.1`) and maintain a changelog.
