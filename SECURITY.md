# Security policy

Please do not disclose vulnerabilities in a public issue. Until a dedicated
security contact is configured for the standalone repository, use GitHub's
private vulnerability reporting feature.

Reports should include the affected version, reproduction steps and expected
impact. Never attach real Claude/Codex credentials or conversation logs.

The project treats credential exposure, unintended conversation-content
storage/transmission, writable access to provider data, signature bypasses and
unsafe update delivery as security-sensitive issues.

## Credential invariants

- Every device creates a separate OAuth authorization; tokens are never copied
  from a Mac, CLI, desktop app, backup or iCloud Keychain.
- Tokens are stored as `ThisDeviceOnly` and non-synchronizable.
- A single actor owns refresh. Concurrent requests share one refresh operation
  and the rotated access/refresh pair is replaced in one Keychain update.
- Authentication codes, verifiers, states and tokens must never be logged,
  placed on the clipboard or included in crash diagnostics.
- Source tests fail if forbidden Claude scopes or known credential-file paths
  are reintroduced into executable source.
