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
- **Usage overview** — manual expansion shows account and session token history above NPU processes, without agent session statistics or a session list; tracking continues in the background. Session history includes observable remote Codex App sessions as well as local sessions. Configured SSH sources backfill timestamped remote token logs after reconnecting or waking, with cumulative counters preventing duplicate usage across logs and live samples. Remote cumulative usage without reliable dates is shown separately, not attributed to a chart day. With Codex usage enabled, the closed right lane shows remaining quota and reset-window time percentages, including rollout rate-limit fallback; unavailable values remain explicit unknowns. Account daily history is read independently through the installed desktop bundle’s CLI even when the desktop UI is closed; the temporary read-only connection neither marks the desktop as online nor discovers sessions. See [remote Codex usage](./remote-codex-usage.md) for collection limits.
- **Remote NPU monitor** — the closed left lane shows `CPU`, `NPU`, or both while the corresponding monitors are connecting, active, or retrying. Hardware utilization stays in the expanded island. The NPU panel shows HBM and AIC percentages per chip above the process list, including when no processes are running; chip lists scroll after four rows. Expand and click SSH to open the connection window. One app-owned direct password SSH session samples only `npu-smi info`, by default every two seconds; terminal SSH sessions are not reused. Verify the host fingerprint on first connection. Credentials remain in memory; the validated address may be remembered. Monitoring continues while collapsed or after closing the connection window, and ends on disconnect or application exit. Missing metrics and stale samples are not reported as zero. The process list preserves chip/PID rows and scrolls after six rows. Agent approval/question/completion notifications retain priority over the overview.
- **Server CPU monitor** — the SSH window offers multi-select buttons for `macserver`, `winserver`, and `winserver2055`, using existing SSH configuration, keys, and verified host keys. Click again to stop monitoring that server. The connection window contains selection and connection status; live metrics appear only in the expanded island, with one section per selected server. Each section uses eight compact, 26-point-high rectangular logical-core tiles per row, total usage, platform, core count, and sample time; hover for CPU model details. The first seven rows per server are visible and larger machines scroll. macOS uses Mach CPU counters; the Windows SSH aliases monitor only WSL using `/proc/stat`, explicitly labeled WSL. A dependency-free Python 3 script is sent over stdin, measuring counter differences over 0.5 seconds, with a default two-second polling interval. Monitoring continues after closing the window. Selected servers and the refresh interval are saved; normal app startup automatically reconnects them. Explicitly deselecting a server removes it from the saved selection, while application shutdown only stops sampling. UI harness runs do not resume saved connections. Stale metrics are marked unknown. The Ascend NPU tab retains its existing connection form, and NPU processes can remain visible alongside CPU monitoring.
- **Remote fan speeds** — selected CPU servers show host fan RPM between the server name and total CPU usage. Intel `macserver` reads AppleSMC actual and hardware maximum speeds, showing each fan's percentage of its own maximum; cyan is below 50%, yellow 50–79%, and orange 80% or above. `winserver2055` reads existing Windows IPMI/WMI tachometers through the `winserver2055-windows` SSH alias while its CPU data remains WSL-only. Its provider exposes no reliable physical maximum, so it shows RPM with absolute speed colors: cyan below 2000 RPM, yellow 2000–3999 RPM, orange 4000 RPM or above. Hover explains the basis and identifies each fan. Sensor ranges and alarm thresholds are never substituted for rated maxima. Colors indicate rotation speed rather than temperature or health. Surface `winserver` has no usable fan interface and shows unknown. Unavailable (`N/A`), failed, or expired sensor reads also show unknown. Fan polling runs independently every five seconds, with bounded SSH timeouts and retries; deselection or shutdown cancels it.
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
