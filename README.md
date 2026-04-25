# cli-buddy

A 13×11-pixel companion that sits on your macOS desktop and mirrors
whatever your Claude Code and Codex sessions are currently doing.
Purple when a session is thinking, amber when a tool is waiting on
approval, green when it's your turn to type. Click it for a list of
live sessions; click a row to jump straight to the matching terminal
tab.

No network calls. Everything reads from local log files and a Unix
socket the bundled hook script writes to.

## Install

Drop the pre-built `.app` into `/Applications` (the build is
unsigned, so the first launch needs a right-click → **Open**, or):

```bash
xattr -dr com.apple.quarantine /Applications/CliBuddy.app
```

Or build from source — see [Building](#building).

On first launch cli-buddy asks for **Accessibility** permission
(needed to roam across screens), writes
`~/.claude/hooks/cli-buddy-state.py`, patches
`~/.claude/settings.json` and `~/.codex/hooks.json`, and binds
`/tmp/cli-buddy.sock`. Hook-config install is idempotent; existing
sessions pick up the hook on their next restart.

## What you see

| Mood | Color | Trigger |
|---|---|---|
| Idle | neutral | no active sessions |
| Thinking | purple | any session in `processing` |
| Waiting | green | any session `waiting_for_input` |
| Attention | amber | any session `waiting_for_approval` or question |
| Celebrating | green flash + hop | a task just finished while others run |

| Interaction | Result |
|---|---|
| Click the buddy | Session-list bubble |
| Click a session row | Jump to its terminal tab |
| Drag | Move the buddy |
| Hover | Pause roaming so you can click |
| ⌘U | Usage panel (today / week / all-time tokens + cost) |
| Menu bar 🐾 N | Badge count of sessions waiting on you |

When a tool asks for permission, an approval bubble anchors itself
next to the buddy with the tool name and input. Enter approves, esc
cancels — no terminal switch needed.

## Settings

| Setting | Range / options |
|---|---|
| Species | Cat, Dog, Pig, Pikachu |
| Pixel size | 3–8 px |
| Roam the desktop | on / off (off = pinned in place) |
| Roam speed | slow / medium / fast |
| Cross-screen roaming | on / off |
| Auto-popup bubbles | on / off (off = badge only) |
| 8-bit sound effects | on / off |

Persists to `UserDefaults`.

## Terminal jump

How each terminal resolves the session's owning tab:

| Terminal | Jump method |
|---|---|
| **Ghostty** | OSC 7 — hook echoes cwd to the tty, Ghostty matches it |
| **Codex Desktop** | `codex://threads/<sessionId>` URL scheme |
| **iTerm2** | AppleScript `session.path` match |
| Terminal.app, Warp, VS Code, Cursor | Bundle-ID activation (app-level, no tab focus) |
| Kitty, WezTerm, Alacritty | Terminal.app fallback |

## How it works

```
hook script (py)
      │  one JSON line per event, Unix socket
      ▼
HookSocketServer  ─ per-client DispatchSource, no blocking reads
      │            PermissionRegistry (actor) holds in-flight fds
      ▼
SessionStore  ─ @MainActor, state machine validates phase changes
      │        publishes two monotonic counters:
      │           structuralRevision  (add / remove / phase change)
      │           tickRevision        (every event, including heartbeats)
      ▼
BuddyBrain (mood aggregator) ─► UI (pixel buddy, bubbles, badge)
```

The dual-signal fan-out means `BuddyBrain` only recomputes mood
when something structural changed — heartbeats don't wake it. The
`RoamingController` is a pure state machine with one `.celebrating`
state that owns the hop arc, so the coordinator runs exactly one
60 fps ticker.

Usage scans go through a generic `JSONLScanner` that streams 64 KiB
chunks and caches per-file results keyed on mtime, so repeated
Usage-panel opens are effectively free until a log file actually
changes.

## Building

Needs **macOS 15+** and Xcode Command Line Tools. Full Xcode is
**not** required — the build uses Swift Package Manager +
[`swift-bundler`](https://github.com/stackotter/swift-bundler) to
produce the `.app`.

```bash
xcode-select --install
brew install mint
mint install stackotter/swift-bundler@main

pnpm build                              # or: bash scripts/build.sh
open .build/bundler/apps/CliBuddy/CliBuddy.app
```

If you're running the manual `swift build` / `swift run` path on a
CLT-only toolchain (no full Xcode), export these once per shell so
the C++ transitive deps compile:

```bash
export SDKROOT=$(xcrun --show-sdk-path)
export CPLUS_INCLUDE_PATH="$SDKROOT/usr/include/c++/v1:$SDKROOT/usr/include"
```

Development loop:

```bash
swift test           # 70 tests via swift-testing
swift run CliBuddy   # launch from source, no bundle
```

## Project layout

```
Sources/CliBuddy/
├── App/          @main + AppDelegate + menu bar
├── Core/         BuddyBrain, RoamingController/Coordinator, ScreenManager,
│                 SoundManager, CustomizationStore
├── Models/       SessionPhase, SessionState, BuddyMood, BuddyCustomization,
│                 SubagentTool, ToolResultData, AnyCodable
├── Services/
│   ├── Hooks/    HookSocketServer, PermissionRegistry, HookInstaller,
│   │             CodexHookInstaller
│   ├── State/    SessionStore
│   ├── Terminal/ Ghostty / Codex / iTerm2 / Terminal jumpers + router
│   └── Usage/    JSONLScanner, UsageService (Claude), CodexUsageService
├── UI/
│   ├── Window/   BuddyWindow, BubbleWindow
│   ├── Components/  PixelBuddyView, BuddySprite, BubbleChrome, ...
│   └── Views/    ApprovalBubble, QuestionBubble, SessionListBubble,
│                 UsageBubble, Settings
└── Resources/
    └── cli-buddy-state.py   bundled hook script
```

Design notes for major refactors live in `docs/plans/`.

## License

ISC.
