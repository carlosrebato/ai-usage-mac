# Contributing

Contributions are welcome. Please keep AI Usage local-first, read-only and
lightweight.

1. Open an issue before large behavioral or data-model changes.
2. Run `swift test` and `Scripts/build-unsigned-artifact.sh`.
3. Add tests for parsing, persistence, cancellation and file rotation changes.
4. Never add real session logs, tokens, credentials, bookmarks or absolute user
   paths to fixtures, commits or workflow output.
5. Avoid dependencies unless they provide clear value that cannot be achieved
   with macOS frameworks without compromising the runtime footprint.

Pull requests that change permissions, entitlements, bundle identity, local data
access or networking must explain the privacy and TCC impact explicitly.
