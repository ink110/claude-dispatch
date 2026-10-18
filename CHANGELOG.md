# Changelog

## 1.0.0 — 2026-10-18

First public release.

### Added

- Menu bar status console for multiple Claude Code sessions.
- Floating request cards for permission prompts, `AskUserQuestion`, and plan approval.
- Long-content handling: panel height is capped to the screen, the body scrolls, and action buttons stay pinned to the bottom.
- First-run onboarding that installs Claude Code hooks and reports their health.
- Universal binary (Apple Silicon + Intel), app icon, and a reproducible packaging script.
- `--uninstall-hooks` CLI so hooks can be removed without jq or manual JSON editing.
- Demo script for injecting long synthetic request cards.

### Fixed

- Launch-at-login registration no longer gets skipped permanently when the app is first run from a build directory.
- Removed hard-coded personal paths from repair messages and tests.
- Uninstall no longer depends on jq.
