# Claude Dispatch

English · [中文](README.md)

A macOS menu bar task console for Claude Code: watch several sessions at once, get notified when a task needs you, and approve or answer right from a floating panel — no jumping back to the terminal.

Runs entirely on your Mac. No network calls, no telemetry. It does not require a Claude account and works with third-party providers such as DeepSeek.

![Permission request card](docs/request-card.png)

> The app UI is currently in Chinese. This English README documents installation and behavior; localization is planned.

## What it solves

When you run several Claude Code tasks at the same time:

1. A task waits for permission and you never notice.
2. Claude asks a question and you have to find that terminal window again.
3. You want to know how many tasks are running and which one is waiting for you.

Claude Dispatch gives you:

- **Always-visible status bar**: shows how many tasks are running and how many requests are waiting. Draggable, visible on every Space and full-screen app.
- **Status panel**: hover or click the bar to list sessions grouped by "needs you / running / idle", with project path, elapsed time, and recent activity.
- **Request panel**: handle permission requests, Claude questions, and plan approvals directly. It shows a plain-language summary first; raw commands stay behind "view technical details".
- **Long content stays usable**: panels cap their height to the screen, the body scrolls, and the submit/allow buttons stay pinned to the bottom.
- **Escalation**: after 15 seconds the card pulses and chimes again; after 45 seconds it raises to the front and moves to the screen under your mouse. It never steals keyboard focus.
- **Click to return to the terminal**: background jobs open with `claude attach`, live sessions focus their Terminal tab, finished sessions resume with `claude --resume`.
- **Self-repair**: if cc-switch rewrites settings and removes the hooks, the status bar shows "click to repair".

![Always-visible status bar](docs/status-bar.png)

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel (universal binary)
- A working installation of [Claude Code](https://claude.com/claude-code)

## Install

### Download (recommended)

1. Download `ClaudeDispatch-1.0.0.zip` from [Releases](https://github.com/ink110/claude-dispatch/releases/latest).
2. Unzip and drag `ClaudeDispatch.app` into Applications.
3. **Right-click → Open the first time.** The app is not notarized by Apple, so a double-click is blocked by Gatekeeper.

   If macOS still refuses to open it, go to System Settings → Privacy & Security and click "Open Anyway", or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudeDispatch.app
   ```

4. On first launch, click "Enable reminders" in the onboarding window. Running Claude Code sessions must be restarted to load the new hooks.

Verify the download with the SHA-256 file published alongside the release:

```bash
shasum -a 256 -c ClaudeDispatch-1.0.0.zip.sha256
```

### Build from source

Requires Xcode Command Line Tools (`swiftc`). No Homebrew, jq, or third-party dependencies.

```bash
git clone https://github.com/ink110/claude-dispatch.git
cd claude-dispatch
./scripts/install.sh
```

`install.sh` builds a universal binary, installs it to `~/Applications/ClaudeDispatch.app`, installs the hooks (backing up `~/.claude/settings.json` first), and launches the app.

## Usage

- **Status bar**: orange dot = tasks running, red dot = requests waiting, yellow text = possibly stuck. Hover to expand; drag to reposition (position is remembered).
- **Permission requests**: plain-language summary, impact, and action buttons. Click "view technical details" to inspect the raw command.
- **Questions**: click single- or multi-select options, or type your own answer. Multiple questions and long content are supported with scrolling.
- **Plan approval**: approve, or type feedback and request changes.
- **Back to terminal**: click "back to terminal" or press Esc to fall back to Claude Code's native prompt.
- **Open a task**: click any task card to open its terminal session.
- **Launch at login**: enabled by default when first launched from an installed location; toggle it at the bottom of the status panel.

### Automation permission (optional)

Focusing the exact Terminal tab requires permission to control Terminal. Without it, Claude Dispatch only brings Terminal to the front; `claude attach` still works.

To trigger the permission prompt explicitly:

```bash
open -n /Applications/ClaudeDispatch.app --args --request-automation
```

## Privacy and security

- The hook server binds only to `127.0.0.1:18765`; every request is authenticated with a random local token (`~/.claude-dispatch/token`, mode 600).
- No network access, no telemetry, no upload of code or conversations.
- Only the `hooks` field of `~/.claude/settings.json` is modified; every change is backed up (five most recent backups kept).
- Nothing is approved silently; even "always allow this kind of operation" requires a click.
- If the app is not running, times out, or returns an error, Claude Code falls back to its native terminal prompt. Tasks are never silently denied.

## How it works

```
Claude Code session
  ├─ claude agents --json ──every 5s──> status bar / status panel (primary source)
  │    └─ repeated failures → fall back to ~/.claude/sessions/<pid>.json
  └─ hooks ──HTTP POST──> 127.0.0.1:18765 ──> request panel ──> allow / deny / answers
```

| Hook event | Purpose |
|---|---|
| `PermissionRequest` | Permission prompts and plan approval; the panel blocks for your decision |
| `PreToolUse` (`AskUserQuestion`) | Answers questions via `updatedInput.answers` |
| `PreToolUse` / `PostToolUse` (`*`, `mode=activity`) | Records current activity; no decisions |
| `Stop` | End of a turn; activity only |
| `Notification` | Waiting-for-input and background-completion notices |
| `SessionStart` / `SessionEnd` | Refresh state and the "recently completed" list |

## Limitations

- Only decision points are covered: permissions, questions, and plan approval. Starting a brand-new task still happens in the terminal.
- One request card is shown at a time; additional requests queue up. Chips at the top switch between them without losing entered answers.
- Plan approval is best-effort: in some Claude Code versions/modes `ExitPlanMode` is handled by the terminal TUI and falls back there.
- The app is not notarized; the first launch requires a right-click or manual approval.
- Status data prefers the official `claude agents --json` interface. A future Claude Code release may change it, in which case the status bar shows a degraded-data indicator.

## Uninstall

```bash
# Adjust for your install location (downloads usually in /Applications; the source install script uses ~/Applications)
/Applications/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch --uninstall-hooks
```

This removes all Claude Dispatch hooks and backs up your settings. Then move `ClaudeDispatch.app` to the Trash and remove Claude Dispatch from System Settings → General → Login Items.

## Development

```bash
./scripts/build.sh          # universal arm64 + x86_64 build
./scripts/test-humanizer.sh # Humanizer unit tests
./scripts/smoke.sh          # curl + /status smoke tests (app must be running)
./scripts/demo-request.sh   # inject a long synthetic question card
./scripts/package.sh        # dist/ClaudeDispatch-<version>.zip + SHA-256
```

Swift + AppKit, no third-party dependencies. See [CLAUDE.md](CLAUDE.md) for source layout and design conventions.

## License

[MIT](LICENSE) © 2026 ink

Claude is a trademark of Anthropic. This is an independent community tool and is not affiliated with or endorsed by Anthropic.
