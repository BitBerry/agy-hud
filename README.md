# agy-hud

An Antigravity display enhancement plugin with a native macOS floating HUD (`AgyHUD.app`) for both the Antigravity desktop app and the `agy` CLI. It tracks live **Context length**, **TPS**, **Context compaction threshold & history**, and **collapsible dual-window model quota** (`Weekly limit` + `5h limit`).

## Features

- **Native macOS Floating HUD (`NSPanel` + SwiftUI)**
  - Non-activating translucent overlay that never steals keyboard focus from Antigravity.
  - Auto-shows when Antigravity, or a terminal running the `agy` CLI, is frontmost and auto-hides when switching apps (can also be pinned Always-on-Top).
  - Freely draggable inside the host window while clamped strictly within its bounds; follows window moves and resizes. The position is remembered separately for Antigravity and for terminals.
- **Antigravity Desktop + `agy` CLI**
  - One HUD follows whichever is in front: the conversation you are viewing in Antigravity, the focused `tmux` pane/window running `agy`, or the most recently active CLI session. A `桌面` / `CLI` badge shows which one is displayed.
  - CLI sessions are found by process, so the terminal can be any app (Ghostty, iTerm2, Terminal, an editor's integrated terminal), including parallel sessions inside `tmux`.
  - Auto-launch on hooks is off by default and can be toggled from the menu bar item (`随 Antigravity / agy 自动启动`).
  - The menu bar item's `数据来源` submenu can lock the HUD to one of the two.
  - Model quota is served only by the desktop app's language server. During CLI-only use the quota row keeps the last synced values and shows their age.
  - Collapsible **Mini Pill** mode displaying live `Context / Compaction Threshold`, remaining compaction percentage (`压剩 XX%`), TPS, and active quota.
- **Context Length**
  - Exact `input_tokens + cache_read_tokens` from `transcript.jsonl`, cache hit rate, per-turn delta, output tokens, and dual-zone progress bar with compaction threshold tick.
- **TPS (Tokens Per Second)**
  - Millisecond-timed last-turn TPS, session average TPS, peak TPS, live generating timer, and a recent-turns sparkline.
- **Context Compaction Length**
  - Displays auto-compaction trigger threshold (calibrated from local `CHECKPOINT` history with per-model defaults), remaining tokens before compaction, and actual compaction history (`pre → post`, savings %, summary tokens).
- **Dual-Window Quota (Collapsed by Default)**
  - Collapsed header shows active group `5h` and `Weekly` remaining percentages at a glance.
  - Expanding reveals full official-style `Weekly limit` and `5h limit` rows with reset countdowns and circular ring gauges across all model groups (`Gemini Models`, `Claude and GPT models`, etc.).
- **Zero Context Overhead & Privacy First**
  - Uses passive lifecycle hooks only (`SessionStart`, `PreInvocation`, `PostInvocation`, `Stop`)—no MCP tools, no `PreToolUse` gating, zero extra tokens in model context.
  - Language server CSRF tokens are passed exclusively over a `0600` local Unix domain socket into `AgyHUD.app` memory and are never written to disk; `quota.json` and `runtime-state.json` (`0600`) strip emails and credentials.

## Requirements

- macOS 14+ (Apple Silicon)
- Xcode Command Line Tools (`swiftc`)
- Node.js 18+
- Google Antigravity App and/or the `agy` CLI (the plugin directory is shared by both)

## Build & Install

```bash
bash scripts/build-and-install.sh
```

The script compiles `AgyHUD.app`, ad-hoc signs it, installs the plugin into `~/.gemini/config/plugins/agy-hud/`, installs `AgyHUD.app` into `~/.gemini/antigravity/plugin_data/agy-hud/AgyHUD.app` (and copies a build artifact to `~/Downloads/AgyHUD.app`), and validates the bundle with `agy plugin validate --strict`.

To launch immediately after install:

```bash
open -g -a ~/.gemini/antigravity/plugin_data/agy-hud/AgyHUD.app
```

## Project Structure

```text
agy-hud/
├── plugin/
│   ├── plugin.json               # Antigravity plugin manifest
│   ├── hooks.json                # Passive telemetry hooks
│   ├── assets/logo.svg           # Plugin icon
│   └── scripts/
│       ├── hook.mjs              # Fast lifecycle hook + Unix socket IPC
│       └── quota-refresh.mjs     # Detached RetrieveUserQuotaSummary / GetUserStatus fetcher
├── macos/
│   ├── Resources/Info.plist      # LSUIElement menu-bar + floating HUD app config
│   ├── Resources/AppIcon.icns    # App icon, generated from plugin/assets/logo.svg
│   └── Sources/                  # Swift / AppKit / SwiftUI source files
└── scripts/
    ├── build-and-install.sh      # Build, sign, install, and strict validation script
    └── make-icon.sh              # Regenerate AppIcon.icns from the plugin logo
```

## License

MIT
