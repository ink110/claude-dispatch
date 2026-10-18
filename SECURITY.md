# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository:
**Security → Report a vulnerability**. Do not open a public issue for
security-sensitive reports.

Please include reproduction steps, the macOS version, and the Claude Code
version. You can expect an initial response within a few days.

## Security model

- Claude Dispatch runs a local HTTP server bound to `127.0.0.1:18765`.
- Every request must include the random token stored at
  `~/.claude-dispatch/token` (mode 600). The token is compared exactly.
- The app makes no outbound network connections and has no telemetry.
- Changes to `~/.claude/settings.json` are limited to the `hooks` entries
  pointing at the local server; a backup is written before each change.
- The distributed `.app` is ad-hoc signed but not notarized. Verify downloads
  against the SHA-256 file published with each release.

## Scope

Reports about Claude Code itself, Anthropic services, or third-party provider
accounts are out of scope for this project.
