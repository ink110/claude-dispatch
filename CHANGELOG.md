# Changelog

## 1.1.1 — 2026-10-25

### Fixed

- Clicking a task that already has a terminal window now focuses that window instead of opening a duplicate. Background jobs look for a running `claude attach <id>`, finished sessions look for `claude --resume <id>`.
- Tab focusing can no longer hang: the AppleScript runs in a killable `osascript` subprocess with a hard timeout. In-process `NSAppleScript` blocked indefinitely when called off the main thread.
- When focusing fails (for example, the automation permission has not been granted yet), the app brings the terminal forward and asks for permission once, rather than opening a second window.
- A background task whose current turn finished now opens with `claude attach` while its session is still alive. It used to run `claude --resume`, which Claude Code rejects for a live background session.
- The task list no longer rebuilds or resets its scroll position while the pointer is over it, so a background refresh can no longer move a different task under the click.

## 1.1.0 — 2026-10-18

### Added

- The README now includes an interface tour with screenshots of the status bar states, the session panel, all three request cards, and first-run onboarding.
- Screenshot mode (`CLAUDE_DISPATCH_DEMO_AGENTS`) renders the interface from a fixed demo dataset without reading real local sessions.

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
