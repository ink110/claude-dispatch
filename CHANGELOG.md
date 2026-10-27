# Changelog

## 1.1.6 — 2026-10-27

### Fixed

- The multi-select checkmark in question cards drew mirrored. Option rows draw inside the flipped scroll document view, and AppKit propagates the flipped coordinate system into subviews' `draw()` (y points down); the check path was written assuming y-up. The path now converts its low/high points for the current context's flipped state.
- The running-state spinner no longer drifts while rotating. The SF Symbol `arrow.triangle.2.circlepath` rasterizes with its glyph center off the image's geometric center at some point sizes (screenshot measurement: bounding-box center drifted 2px across rotation phases at 16pt), so the arrows orbited an off-center point. The spinner is now a custom `CAShapeLayer` arc whose circle is centered in the layer by construction (same measurement: ≤0.5px, the 1× rasterization floor, at all sizes in both plain and flipped containers). Apple's designated spinner symbol `progress.activity` renders blank in an AppKit `NSImageView` on macOS 26, so it cannot be used directly.

## 1.1.5 — 2026-10-26

### Fixed

- Clicking a task opened a duplicate window when its conversation was already on screen in a window the user had opened manually by running `claude agents` in Terminal. That window has no `claude attach` process and no launcher script, so neither the process scan nor the window registry could find it. Terminal tab titles follow the Claude Code session name (for example `◑ 插件迭代2.0`), so as a last resort the app now recognizes the window by its tab title and focuses it without injecting any command into the terminal.
  - Windows claimed this way are recorded in `~/.claude-dispatch/windows.json` with a `manual` flag and re-validated by tab title on every click; when the title no longer matches (session renamed or window closed), the registration is dropped and the title scan runs again before any new window is opened.

## 1.1.4 — 2026-10-25

### Fixed

- Clicking a task opened a second window when its existing window was still on screen but the conversation had already exited inside it. The window was no longer discoverable in the process table.
  - Launcher scripts now leave an interactive shell after `claude attach` / `claude --resume`, so their window stays discoverable for as long as it is open.
  - When the task's window is found but the conversation has exited, Claude Dispatch focuses that window and re-runs `claude attach` in the same tab instead of opening a duplicate. If the tab is running something else (for example the agent view), it only focuses it.
  - Windows created by earlier versions (without the trailing shell) are remembered once they are focused; after their conversation exits, clicking the task still finds the window by its tty instead of opening a new one. Registrations are dropped when the tab is gone or has been reused by another running process.
  - Process matching also accepts `claude.exe` as the executable name.

## 1.1.3 — 2026-10-25

### Fixed

- Clicking any task in the panel always opened the last task in the list. The clickable row's `hitTest` returned itself unconditionally; inside an `NSStackView` every click reaches the last row first, so the last row swallowed the entire content area. The row now only claims hits that fall inside its own frame or bounds.

## 1.1.2 — 2026-10-25

### Fixed

- Clicking a task could open a new, empty Claude window instead of the task's conversation. The session panel was listing Claude Code's pre-warmed background slots (`spare: true` in the session registry) as tasks — they have no conversation, so attaching to one falls back to a blank agent view. Those internal slots are now hidden.
- Duplicate windows are now prevented even when the task's Claude process no longer shows the attach id in its command line (for example, after pressing ← to return to the agent view): the launcher script name carries a task marker that is matched against the process table.
- Clicking the same task twice before its terminal window has finished opening no longer opens two windows; the second click only brings Terminal forward.

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
