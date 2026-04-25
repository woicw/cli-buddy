# Performance Refactor — Design

Date: 2026-04-21
Status: Approved, pending implementation plan
Scope: cli-buddy v0.1.0 → v0.2.0 (in-place, behavior-preserving)

## Goal

Remove the concrete performance and stability risks identified in the
2026-04-21 architecture survey while preserving every user-visible
behavior and every existing test.

## Non-goals

- No new runtime dependencies.
- No change to the hook wire protocol, `UserDefaults` keys, socket
  path, or installed-hook script contract.
- No rewrite of `SessionPhase`, `BuddyMood`, `BuddySprite`, or any
  unit-tested pure-logic module.
- No `.app` bundle size regression beyond a few KB.

## Success criteria

- All 54 existing tests pass unchanged.
- At least one regression test per fixed risk.
- `PixelBuddyView` creates no lingering `Timer` instances across
  re-renders (verified by a leak-detection test).
- `RoamingCoordinator` runs exactly one 60 fps ticker at any moment
  (verified by instance count invariant).
- `SessionStore` cosmetic `lastEventAt` updates do not trigger a
  `BuddyBrain` recomputation (verified by a subscription-count test).
- `UsageService` / `CodexUsageService` re-query latency on an
  unchanged log set is bounded by cache lookup, not file I/O
  (verified by mtime-cache hit test).
- `swift build` on CLT-only toolchain still succeeds via the existing
  `scripts/build.sh` path; `.app` still produced at
  `.build/bundler/apps/CliBuddy/CliBuddy.app`.

## Architecture risks targeted

Sourced from the 2026-04-21 survey; each is addressed in exactly one
phase below.

| # | Risk | File / line | Phase |
|---|------|-------------|-------|
| R1 | `Timer` leak on every view rebuild | `UI/Components/PixelBuddyView.swift:61` | 1 |
| R2 | Two 60 fps tickers race during celebrate() | `Core/RoamingCoordinator.swift:73,122` | 1 |
| R3 | Blocking 500 ms socket reads per client | `Services/Hooks/HookSocketServer.swift:422–442` | 2 |
| R4 | `NSLock` contention on `pendingPermissions` | `Services/Hooks/HookSocketServer.swift:139,503–524` | 2 |
| R5 | Full-dict republish on every `lastEventAt` tick | `Services/State/SessionStore.swift:65` | 3 |
| R6 | Full JSONL rescan on every usage query | `Services/Usage/UsageService.swift:114–121`, `CodexUsageService.swift:40–48` | 4 |
| R7 | Duplicated JSONL scanner logic | same as R6 | 4 |

## Phased approach

Each phase is one reviewable commit on a single feature branch. Any
phase may be reverted independently. Phases land in order; no phase
merges red.

### Phase 1 — UI lifecycle (R1, R2)

**PixelBuddyView walk-cycle**

Replace the `Timer.scheduledTimer` attached in `onAppear` with a
`TimelineView(.periodic(from: .now, by: 0.25))` driving the
`walkToggle` state. `TimelineView` is SwiftUI-owned: its scheduler
binds to the view's lifetime and is cancelled automatically on
disappear. Removes the leak, simplifies the view, preserves the
4 Hz cadence exactly.

Test: instantiate the view N times inside a host, drop references,
assert no active `Timer` for its selector remains (use
`CFRunLoopGetCurrent().timerCount` delta, or a weak-reference
sentinel stored by the old timer target).

**RoamingCoordinator celebrate()**

Fold celebration into `RoamingController` as a new state
`case celebrating(origin: CGPoint, peak: CGPoint, progress: Double)`.
`tick()` advances `progress` and returns a CGPoint per frame exactly
as the duplicate timer used to. `RoamingCoordinator` keeps one timer;
`celebrate()` becomes `controller.startCelebration(at:)`. The
`isSuspended` flag is deleted — state machine owns the invariant.

Test: extend `RoamingControllerTests` with a celebration sequence;
assert coordinator count of live timers stays at 1 across
`celebrate()` calls.

### Phase 2 — Socket server hardening (R3, R4)

**Read path**

Replace the `poll(2)` + `recv` loop in `handleClient` with a
`DispatchSource.makeReadSource(fileDescriptor:queue:)` per accepted
client FD. The source fires only when data is available; the current
queue (`socketQueue`, `qos: .userInitiated`) keeps ordering. A
newline-framed `LineReader` accumulates bytes and dispatches
complete events. JSON decode is unchanged.

This removes the 500 ms wall-clock block per client and the nested
synchronous poll loop. Accept loop continues to run on the same
queue; a slow client can no longer starve it.

**Permission registry**

Extract `pendingPermissions` and its locking into
`actor PermissionRegistry`. Public API:

```swift
actor PermissionRegistry {
    func register(id: String, client: ClientHandle) async
    func resolve(id: String, decision: PermissionDecision) async -> ClientHandle?
    func expire(olderThan: Date) async
}
```

`HookSocketServer` calls into the actor with `await`; the `NSLock`
and direct dict access are removed. `cacheLock` stays scoped to the
tool-use-id cache (less contention, unchanged semantics).

Test: add a permission round-trip test —
open socket → send `PermissionRequest` → receive decision response
on same FD — and a concurrency test registering N requests in
parallel and asserting no dropped entries.

### Phase 3 — State fan-out (R5)

Split `SessionStore`'s output into two publishers:

- `@Published sessionsChanged: Int` — monotonic counter incremented
  only on structural change (add / remove / phase transition /
  tool-use change).
- `@Published sessionsTicked: Int` — incremented on cosmetic updates
  (`lastEventAt` only).

The underlying `sessions: [String: SessionState]` dictionary remains,
but its `didSet` is replaced by explicit `notifyStructural()` /
`notifyTick()` calls inside `apply()`. Public shape of
`SessionState` is unchanged.

Subscribers:

- `BuddyBrain` listens to `sessionsChanged` only — mood
  recomputation no longer fires on heartbeats.
- `SessionListBubbleView` listens to both, debounced at 4 Hz via
  `Publishers.throttle(for:)`.
- Menu-bar badge listens to `sessionsChanged`.

Test: record `BuddyBrain.mood` recomputation count; feed 100
`lastEventAt` ticks; assert the count is 0. Feed one phase
transition; assert the count is 1.

### Phase 4 — Unified streaming JSONL scanner (R6, R7)

**New module**: `Services/Usage/JSONLScanner.swift`

```swift
struct JSONLScanner<Event: Decodable> {
    init(directory: URL, pattern: String)
    func scan(decode: (Data) -> Event?) async -> [Event]
}
```

Implementation:

- Enumerates matching files via `FileManager.enumerator`.
- For each file, consults an in-memory mtime cache
  (`[URL: (mtime: Date, events: [Event])]`). Cache survives the
  process lifetime; files with unchanged mtime return cached events.
- Changed/new files stream via `FileHandle.bytes.lines` (async
  sequence, no full-file allocation) and decode line by line.
- Cache persisted nowhere — mtime + memory only. Surviving restarts
  is a non-goal; first scan after launch matches current behavior.

`UsageService` and `CodexUsageService` are rewritten as thin
adapters: each constructs a scanner and folds the returned events
into the existing `UsageBreakdown` shape. Public API of both
services is unchanged. Expected reduction: ~200 LOC.

Test:
- Round-trip: create tempdir with 3 JSONL files → scan → assert
  expected breakdown.
- Cache hit: scan twice without modifying files → assert second scan
  performs zero `FileHandle.read`.
- Cache miss on mtime change: touch one file → scan → assert only
  that file re-read.

### Phase 5 — Optional: AppDelegate decomposition

Only undertaken if Phases 1–4 land cleanly within the time budget.

Extract into `Core/RootCoordinator.swift`:

- `SessionStore` + `BuddyBrain` wiring.
- `HookSocketServer` lifecycle.
- `RoamingCoordinator` and `ScreenManager` ownership.
- Bubble window coordination (approval / question / session list).

`AppDelegate` is reduced to:

- `NSApplication.shared` wiring.
- Menu bar item + badge.
- First-launch Accessibility permission prompt.
- Ownership of the single `RootCoordinator` instance.

Net: `AppDelegate.swift` drops from 452 LOC toward ~120 LOC.
`RootCoordinator` absorbs the remainder, fully testable without
`NSApplication`.

No behavior change. Purely a layering refactor; deferred by design.

## Data flow after refactor

```
                    ┌───────────────────────┐
                    │   Hook script (py)    │
                    └──────────┬────────────┘
                               │ JSON line, Unix socket
                               ▼
            ┌─────────────────────────────────────┐
            │ HookSocketServer                    │
            │  • DispatchSource per client FD     │
            │  • LineReader framing               │
            │  • PermissionRegistry (actor)       │
            └──────────┬──────────────────────────┘
                       │ HookEvent → MainActor
                       ▼
            ┌─────────────────────────────────────┐
            │ SessionStore (@MainActor)           │
            │  • apply(event)                     │
            │  • notifyStructural / notifyTick    │
            └──────┬───────────────────────┬──────┘
                   │ structural            │ tick
                   ▼                       ▼
            ┌────────────┐          ┌──────────────────┐
            │ BuddyBrain │          │ SessionListBubble│
            └─────┬──────┘          │ (4 Hz throttle)  │
                  │ mood            └──────────────────┘
                  ▼
            ┌────────────────────────────┐
            │ RoamingController (state   │
            │ machine: idle/stroll/      │
            │ summon/sleep/celebrating)  │
            └──────────┬─────────────────┘
                       │ CGPoint per tick
                       ▼
            ┌────────────────────────────┐
            │ RoamingCoordinator         │
            │  • single 60 fps timer     │
            │  • moves NSPanel           │
            └────────────────────────────┘
```

## Testing strategy

- Every phase ships at least one new regression test targeting the
  risk it closes.
- `swift test` runs green at every commit.
- No test doubles for `NSPanel`, `NSApplication`, or the real socket;
  socket tests bind on an ephemeral path in `NSTemporaryDirectory()`
  (already the pattern in `HookSocketServerTests`).
- `JSONLScanner` tests use `NSTemporaryDirectory()` with synthetic
  JSONL fixtures; no network, no home-directory access.

## Error handling

No behavior changes. Existing patterns preserved:

- Socket decode failure → event dropped, client kept open,
  debug-level log (previously silent).
- Usage scanner file read failure → file skipped, zero impact on
  other files.
- Permission decision timeout → unchanged (300 s, inherited).
- Socket bind failure → unchanged (`NSAlert` + red menu-bar tint).

## Rollback plan

Each phase is one commit on the feature branch. If a regression
surfaces post-merge, revert the offending commit; earlier phases are
independent and stay. `main` tag `v0.1.0` remains the safe rollback
point for the entire refactor.

## Out-of-scope (not this refactor)

- `SoundManager` player-node pool (low-impact leak, flagged in
  survey; out of scope).
- Canvas pixel-grid memoization (measured fast enough at 60 fps).
- `ScreenManager` cursor-poll → event-driven migration (acceptable
  at 0.3 s).

## Follow-on work

- If Phase 5 lands, evaluate replacing `ObservableObject` with Swift
  `Observation` (`@Observable`) in a separate PR — out of scope here
  to avoid compounded risk.
- Consider persisting `JSONLScanner` cache to
  `~/Library/Caches/CliBuddy/usage/` after v0.2.0 if first-scan
  latency ever matters (currently unmeasured).

## Amendments during implementation

- **PermissionRegistry omits `expire(olderThan:)`**: external 300 s
  timeout inherited from the hook script, plus `SessionEnd`-driven
  cleanup, covers the same ground. Adding time-based expiry would be
  dead code.

- **CodexUsageService does not sit on top of `JSONLScanner`**: Codex
  rollout files require a per-file reducer (take the last
  `token_count` event in the file). The generic scanner's line-level
  cache doesn't fit. The Codex path reuses the scanner's 64 KiB
  streaming chunk pattern inline. If the scanner ever gains a per-file
  reducer hook, migrating Codex onto it is a follow-up.

- **`RoamingController.tickCelebrate` completion**: at the end of a
  hop, `strollPauseRemaining = 1.0` and `pickStrollTarget()` is
  deliberately deferred. The plan originally specified `pickStrollTarget()`
  inline, but that moves the buddy off the celebration origin on the
  very next tick and violates the "return to origin" intent the test
  encodes. The 1 s rest matches the lower bound of the existing
  stroll-pause range.

- **macOS mtime cache keying**: `JSONLScanner.Cache` keys on
  `Int64` milliseconds derived from `timeIntervalSince1970`. `Date`
  equality is unreliable across `setAttributes([.modificationDate:])`
  round-trips because of sub-millisecond float precision loss.

- **Phase 5 (AppDelegate decomposition) skipped** in this cycle —
  purely a layering refactor with no automated test coverage for the
  bubble wiring. Revisit when time and smoke-test capacity allow.
