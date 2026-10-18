# Claude Dispatch

English · [中文](README.md)

A macOS menu bar task console for Claude Code: watch several sessions at once, get notified when a task needs you, and approve or answer right from a floating panel — no jumping back to the terminal.

Runs entirely on your Mac. No network calls, no telemetry. It does not require a Claude account and works with third-party providers such as DeepSeek.

![Permission request card](docs/request-card.png)

## What it solves

When you run several Claude Code tasks at the same time:

1. A task waits for permission and you never notice.
2. Claude asks a question and you have to find that terminal window again.
3. You want to know how many tasks are running and which one is waiting for you.

Claude Dispatch does that with one always-visible status bar, a session panel, and three kinds of request cards. New here? The tour below shows every state and every panel in about three minutes.

## Interface tour

### 1. The status bar

The bar sits in the top-right corner of the screen (draggable, position remembered) and shows only **the single most important thing right now**. It never steals keyboard focus and stays visible on every Space and full-screen app.

| State | Status bar | When it appears |
|---|---|---|
| Needs you | ![Needs you](docs/state-pending.png) | A permission prompt, a question, or a plan is waiting. **This is the only state that needs action**: click the bar or the card. |
| Running | ![Running](docs/state-running.png) | At least one task is running. Nothing to do. |
| Waiting for input | ![Waiting for input](docs/state-waiting.png) | Claude is waiting for typed input in the terminal, but the app has no card to show (for example, hooks disconnected or a background task waiting). Click the bar to find the session. |
| Completed | ![Completed](docs/state-completed.png) | Recently finished tasks, kept for 10 minutes so you can revisit or reopen them. |
| Idle | ![Idle](docs/state-idle.png) | Nothing is running and nothing is waiting. |

Priority from top to bottom: needs you → waiting for input → possibly stuck → running → completed → idle. A small **yellow dot** means the data source is degraded (`claude agents` is unavailable and the session registry is being used as a fallback).

- Hover: expand the session panel; move away to collapse.
- Click: pin or unpin the panel.
- Drag: move it; the position is remembered.
- The menu bar item mirrors the state: a red bell with a count when something needs you, a waveform and the running count otherwise.

### 2. Session panel (every session at a glance)

Hover or click the bar to expand. Sessions are grouped by state; each row shows the project name, background/interactive kind, path, elapsed time, and recent activity.

![Session panel](docs/status-panel.png)

- **Needs you**: a card is queued; click the row to open its terminal.
- **Waiting for input**: the terminal itself is waiting for typed input, but there is no card to click.
- **Possibly stuck**: the task is busy but has produced no activity for five minutes.
- **Running / Completed / Idle**: everything else.
- Click any row to open its terminal session: background jobs use `claude attach`, interactive sessions focus the matching Terminal tab, finished sessions resume with `claude --resume`.
- Footer: refresh, toggle launch at login, quit.

### 3. Request cards: permissions, questions, plans

All three decision points appear directly under the status bar. By default the card shows a plain-language summary of what will happen, what it affects, and what you need to decide. Raw commands stay behind "view technical details".

#### Permission request

![Permission request card](docs/request-card.png)

- Plain-language summary and impact (install dependencies, delete files, push code, and so on).
- "Deny" or "Allow"; click "view technical details" to inspect the raw command.
- "Always allow this kind of operation" also requires an explicit click. Nothing is approved silently.

#### Claude question

![Claude question card](docs/question-card.png)

- Single-select: click an option. Multi-select: check several. Each option has a short explanation.
- You can also skip the options and type your own answer.
- Long or multiple questions scroll; the submit button stays pinned to the bottom.

#### Plan approval

![Plan approval card](docs/plan-card.png)

- Scroll through the plan; even long plans keep the buttons on screen.
- Approve directly, or type feedback and request changes.

#### Shared interactions

- **Multiple requests queue**: one card at a time, switch with the chips at the top; switching keeps what you already typed.
- **Keyboard**: click the card to focus it, then `⌘↩` to allow/submit, `Esc` to hand the decision back to the terminal.
- **Back to terminal**: click "back to terminal" or press `Esc`.
- **Escalation**: after 15 seconds the card pulses and chimes again; after 45 seconds it raises to the front and moves to the screen under your mouse. It never steals keyboard focus.
- **Long content**: panels cap their height to the screen, the body scrolls, and action buttons stay pinned to the bottom.

### 4. First-run onboarding

![First-run onboarding](docs/onboarding.png)

The first launch installs the Claude Code hooks and checks their health. When it says reminders are enabled, you are ready. Already-running Claude Code sessions must be restarted to load the new hooks. If another tool (for example cc-switch) later rewrites `settings.json`, the status bar changes to "reminder service error · click to repair" and one click fixes it.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel (universal binary)
- A working installation of [Claude Code](https://claude.com/claude-code)

> The app UI is currently in Chinese. This English README documents installation and behavior; localization is planned.

## Install

### Download (recommended)

1. Download `ClaudeDispatch-1.1.0.zip` from [Releases](https://github.com/ink110/claude-dispatch/releases/latest).
2. Unzip and drag `ClaudeDispatch.app` into Applications.
3. **Right-click → Open the first time.** The app is not notarized by Apple, so a double-click is blocked by Gatekeeper.

   If macOS still refuses to open it, go to System Settings → Privacy & Security and click "Open Anyway", or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudeDispatch.app
   ```

4. On first launch, finish the onboarding window to enable reminders. Running Claude Code sessions must be restarted to load the new hooks.

Verify the download with the SHA-256 file published alongside the release:

```bash
shasum -a 256 -c ClaudeDispatch-1.1.0.zip.sha256
```

### Build from source

Requires Xcode Command Line Tools (`swiftc`). No Homebrew, jq, or third-party dependencies.

```bash
git clone https://github.com/ink110/claude-dispatch.git
cd claude-dispatch
./scripts/install.sh
```

`install.sh` builds a universal binary, installs it to `~/Applications/ClaudeDispatch.app`, installs the hooks (backing up `~/.claude/settings.json` first), and launches the app.

## Quick reference

| I want to… | Do this |
|---|---|
| See how many tasks are running | Look at the status bar in the top-right corner |
| Find a session | Hover or click the bar, then click its row |
| Handle a permission, question, or plan | Click the card, or click it once and press `⌘↩` |
| Handle it in the terminal instead | Click "back to terminal" or press `Esc` |
| Switch between queued requests | Click the chips at the top of the card |
| Move the status bar | Drag it |
| Turn off launch at login | The checkbox at the bottom of the session panel |
| Repair broken hooks | Click the bar when it says "click to repair" |

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

Screenshot/documentation mode: `CLAUDE_DISPATCH_DEMO_AGENTS=<agents.json> CLAUDE_DISPATCH_SHOW_FLOATING_STATUS=1 build/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch` renders the session panel from a fixed demo dataset without reading real local sessions.

Swift + AppKit, no third-party dependencies. See [CLAUDE.md](CLAUDE.md) for source layout and design conventions.

## License

[MIT](LICENSE) © 2026 ink

Claude is a trademark of Anthropic. This is an independent community tool and is not affiliated with or endorsed by Anthropic.
