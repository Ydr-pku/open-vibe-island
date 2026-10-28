# Product Scope

## Problem

CLI coding agents are powerful, but they pull attention away from the editor and terminal. Developers need a lightweight control surface to monitor work, approve actions, answer questions, and return to the right session quickly — without handing their machine over to a closed-source paid app.

## Target User

- macOS developers using terminal-based coding agents daily
- Users running more than one agent or more than one terminal session
- Users who care about low latency, native behavior, and open-source transparency

## Product Principles

- **Open source** — all code is public, all contributions are AI-produced
- **Local first** — no server dependency, no accounts, no analytics
- **Native macOS** — SwiftUI + AppKit, not a web wrapper
- **Terminal-native** — built to support the terminal workflow, not replace it
- **Fail open** — if the app or bridge is unavailable, agents keep running unchanged

## Supported Code Agents

| Agent | Status | Notes |
|---|---|---|
| **Claude Code** | Supported | Hook integration, JSONL session discovery, status line bridge, usage tracking |
| **Codex** | Supported | Full hook integration (SessionStart, UserPromptSubmit, Stop), usage tracking |
| **OpenCode** | Supported | JS plugin integration, permission/question flows, process detection |
| **Qoder** | Supported | Claude Code fork — same hook format, config at `~/.qoder/settings.json` |
| **Qwen Code** | Supported | Claude Code fork — same hook format, config at `~/.qwen/settings.json` |
| **Factory** | Supported | Claude Code fork — same hook format, config at `~/.factory/settings.json` |
| **CodeBuddy** | Supported | Claude Code fork — same hook format, config at `~/.codebuddy/settings.json` |
| **Gemini CLI** | Supported | Hook integration (`SessionStart`, `BeforeAgent`, `AfterAgent`, `SessionEnd`, `Notification`), session tracking, terminal jump metadata, completion-card compatibility handling |
| **Kimi CLI** | Supported | Hook integration via `~/.kimi/config.toml` `[[hooks]]` (Moonshot AI). Kimi's hook payload is byte-compatible with Claude Code, so runtime reuses the Claude decode path; a dedicated TOML installer preserves user-authored hooks |

## Supported Terminals

| Terminal | Status | Notes |
|---|---|---|
| **Terminal.app** | Full Support | Jump-back with TTY targeting |
| **Ghostty** | Full Support | Jump-back with ID matching |
| **cmux** | Full Support | Jump-back via Unix socket API |
| **Kaku** | Full Support | Jump-back via CLI pane targeting |
| **WezTerm** | Full Support | Jump-back via CLI pane targeting |
| **iTerm2** | Full Support | Jump-back with session ID / TTY matching |
| **tmux** (multiplexer) | Full Support | Jump-back with session/window/pane targeting |
| **Warp** | Planned | Fallback detection only |

## Features

- **Notch overlay** — sits in the notch area on notch Macs, falls back to a compact top-center bar on external displays or non-notch Macs
- **Usage overview** — manual expansion shows account and session token history above NPU processes, without agent session statistics or a session list; tracking continues in the background. Session history includes observable remote Codex App sessions as well as local sessions. Remote cumulative usage without reliable dates is shown separately, not attributed to a chart day. With Codex usage enabled, the closed right lane shows remaining quota and reset-window time percentages, including rollout rate-limit fallback; unavailable values remain explicit unknowns. See [remote Codex usage](./remote-codex-usage.md) for collection limits.
- **Remote NPU monitor** — the closed left lane shows a gray NPU when disconnected and aggregate HBM used / average AI Core utilization when connected. Expand and click SSH to open the connection window. One app-owned direct password SSH session samples only `npu-smi info`, by default every two seconds; terminal SSH sessions are not reused. Verify the host fingerprint on first connection. The address is remembered and a successfully verified password is stored in the user's macOS Keychain. Unexpected network interruptions retry with bounded backoff; app relaunch restores the last successful connection, while an explicit disconnect stops automatic recovery. Authentication and host-identity failures require user action. If Keychain access fails, the current connection can still retry during that app session and the interface reports the failure. Monitoring continues while collapsed or after closing the connection window. Missing metrics and stale samples are not reported as zero. The process list preserves chip/PID rows and scrolls after six rows. Agent approval/question/completion notifications retain priority over the overview.
- **Settings** — hook install/uninstall, usage dashboard, General, Display, Sound, Shortcuts, Lab, About
- **Notification mode** — auto-height panel for permission requests, questions, and task completion reminders, independent of the compact usage overview
- **Notification sounds** — configurable system sounds with mute toggle
- **i18n** — English and Simplified Chinese
- **Session discovery** — auto-discover from local transcripts, persist across launches
- **Process discovery** — match active agents via `ps`/`lsof`
- **DMG packaging** — signing, notarization, GitHub Actions release workflow
- **Auto-update** — Sparkle-based automatic updates with appcast

## Success Criteria

- Agent events appear in the overlay with low latency
- Approval and answer actions round-trip back to the source process
- The app can restore focus to the owning terminal window reliably
- Idle resource usage remains low enough for all-day background use

## Future Directions

- Warp precision jump support
- Sound packs, themes, and onboarding polish
- Deeper terminal split targeting
