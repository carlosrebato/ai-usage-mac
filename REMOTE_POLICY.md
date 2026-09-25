# Signed remote policy

The macOS app reads a small public file from
`https://raw.githubusercontent.com/carlosrebato/ai-usage-mac/main/remote-policy.json`
at most once per 24 hours. The URL and P-256 public key are embedded at build
time. The private key is a device-only item in the maintainer's local Keychain;
it is not in this repository, the app, or GitHub Actions.

This is an emergency brake for **direct provider requests**, not a way to make
undocumented endpoints official or to change the app's code. A disabled direct
adapter may still yield to a documented local fallback on macOS. A policy may
only name `claude` and/or `codex`, require a minimum app version, and display a
short notice. The initial policy disables neither provider.

## Publish a policy

1. Edit `remote-policy.source.json`: set `issuedAt` to the current UTC time,
   `expiresAt` to a time no more than 30 days later, and choose the providers
   to pause. The source uses ISO-8601 timestamps. Use an empty array to resume
   both direct adapters. The app's current version is in `project.yml`.
2. On the signing Mac, run:

   ```sh
   swift Scripts/remote-policy.swift sign remote-policy.source.json remote-policy.json
   swift test --filter ProviderKillSwitchTests
   ```

3. Review the source and signed file together in a PR, merge to `main`, and
   verify that the raw GitHub URL serves the new signed file. The app cannot
   obey an unsigned or modified file. For an emergency, account for GitHub/CDN
   propagation **and up to 24 hours** before each installed app checks again.

If the file is unavailable or invalid, the app retains its last verified policy
until that policy expires; it never trusts an unsigned replacement. Once a
policy expires, direct requests resume. To lift a pause sooner, publish a new
signed policy with an empty `disabledProviders` array—do not merely delete the
file. The existing beta 3 has no embedded URL or key and cannot be controlled
retroactively. Only a later build can use this policy.

## Key custody

`swift Scripts/remote-policy.swift create-key` was run once on the maintainer's
Mac. **Do not run it again**, overwrite the Keychain item, paste the private
key into an issue or commit, or move it into CI. `public-key` prints only the
public half. The Keychain item is `WhenUnlockedThisDeviceOnly`; it does not
migrate to another Mac. If this Mac or item is lost, an app release embedding a
new public key is required before policies can be signed again. Treat recovery
of the signing Mac as part of release operations.
