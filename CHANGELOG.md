# Changelog

## Unreleased

### Changed

- Redesigned the UI to follow Apple Human Interface Guidelines: standard popover materials, no opaque cards or hard borders, truly rounded material corners without window-shadow outlines, SF Symbols at consistent optical sizes, subtler hairlines, and reduce-motion-aware transitions.
- Panels now use a separate rounded shadow window, so they keep soft depth without the dark rectangular outline produced by `NSWindow.hasShadow` on transparent windows.
- Status icons now cross-fade on state changes; panels fade in briefly instead of appearing abruptly.
- Question options use a native-style circular selection indicator so selection is not communicated by color alone.

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
