# Performance Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land the 4-phase (+ optional Phase 5) in-place refactor from `docs/plans/2026-04-21-performance-refactor-design.md` — fix concrete perf/stability risks without changing any user-visible behavior.

**Architecture:** Five independent, reviewable commits on `main` (or a feature branch, at the executor's discretion). Each phase ships with a red-first regression test; `swift test` is green at every commit; any phase can be reverted in isolation.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Combine, swift-testing (via `Testing` module), Swift Package Manager, macOS 15+, `swift-bundler` for `.app` packaging.

---

## Conventions for every task

- **Run the failing test first.** The TDD loop is non-negotiable — if the test passes before the implementation change, the test is wrong (or the bug already fixed); stop and re-read the task.
- **Build command:** `swift build` (CLT toolchain). If `SDKROOT` is unset, run `export SDKROOT=$(xcrun --show-sdk-path)` first. The release path in `scripts/build.sh` exports this automatically; for tests we rely on the ambient env.
- **Test command (single test):** `swift test --filter <SuiteName>.<testName>`.
- **Test command (whole suite):** `swift test`.
- **Commit style:** Conventional Commits, lowercase type, area scope in parentheses. Examples from history: `feat(state): ...`, `docs: ...`, `style(icon): ...`. No trailing Co-Authored-By required by this repo's history (no human co-authors on recent commits); executors running via Claude Code should use their standard commit footer (`Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`).
- **One task = one commit.** Do not bundle tasks. If a task's implementation is small (< 5 lines), that's fine; the commit still lands.

---

## Phase 1 — UI lifecycle fixes

Fixes R1 (timer leak in `PixelBuddyView`) and R2 (double 60 fps ticker in `RoamingCoordinator.celebrate()`). Both are self-contained; Task 1.1 is independent of 1.2/1.3.

### Task 1.1: Replace Timer with TimelineView in PixelBuddyView

**Why:** `PixelBuddyView.swift:61` creates a `Timer.scheduledTimer` in `onAppear` and never invalidates it. SwiftUI rebuilds `PixelBuddyView` whenever `mood` changes (driven by `BuddyBrain.displayMood`), so every mood change spawns a new timer that retains a closure referencing `walkToggle`. Over hours of use this leaks. `TimelineView(.periodic:)` is lifetime-bound to the enclosing view — no manual timer needed.

**Files:**
- Modify: `Sources/CliBuddy/UI/Components/PixelBuddyView.swift:25-66`
- Test: `Tests/CliBuddyTests/PixelBuddyFrameTests.swift` (existing file — add one test case)

**Step 1: Write the failing test**

Open `Tests/CliBuddyTests/PixelBuddyFrameTests.swift` and append a test that asserts the **walk-cycle phase is derivable from a `Date`** (what `TimelineView` passes). This is the contract we're about to introduce.

```swift
    @Test func walkToggleFromDateIsPeriodicAt4Hz() {
        // Two dates 0.25s apart must land on different walk frames.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.25)
        let toggle0 = PixelBuddyView.walkToggle(at: t0)
        let toggle1 = PixelBuddyView.walkToggle(at: t1)
        #expect(toggle0 != toggle1)
    }

    @Test func walkToggleFromDateIsStableWithinFrame() {
        // Two dates 0.05s apart must land on the same walk frame.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 0.05)
        #expect(PixelBuddyView.walkToggle(at: t0) == PixelBuddyView.walkToggle(at: t1))
    }
```

**Step 2: Run test to verify it fails**

```bash
swift test --filter CliBuddyTests.PixelBuddyFrameTests/walkToggleFromDateIsPeriodicAt4Hz
```
Expected: compile error — `PixelBuddyView.walkToggle(at:)` does not exist.

**Step 3: Write minimal implementation**

Replace `PixelBuddyView.swift` entirely with:

```swift
import SwiftUI

/// Renders the chosen species as a 13×11 grid of filled SwiftUI
/// rectangles. Body pixels take the current mood color, eyes render
/// white, and accents render in the species-specific accent color
/// (dog nose, pig snout, pikachu cheeks).
struct PixelBuddyView: View {
    let species: BuddySpecies
    let mood: BuddyMood
    let pixelSize: CGFloat

    init(species: BuddySpecies = .cat, mood: BuddyMood, pixelSize: CGFloat = 4) {
        self.species = species
        self.mood = mood
        self.pixelSize = pixelSize
    }

    /// Derive the walk-cycle toggle from an absolute Date. 4 Hz cadence
    /// (0.25 s per frame) — pure function so tests don't need a clock.
    static func walkToggle(at date: Date) -> Bool {
        let quarterSeconds = Int(date.timeIntervalSinceReferenceDate / 0.25)
        return quarterSeconds.isMultiple(of: 2) == false
    }

    static func frame(for mood: BuddyMood, walkToggle: Bool) -> BuddySprite.Frame {
        guard mood != .idle else { return .idle }
        return walkToggle ? .walk1 : .walk2
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let walkToggle = Self.walkToggle(at: context.date)
            let frame = Self.frame(for: mood, walkToggle: walkToggle)
            let lit = BuddySprite.keys(for: frame, species: species)
            let eyes = BuddySprite.eyeKeys(for: species)
            let accents = BuddySprite.accentKeys(for: species)
            let accentColor = Color(hex24: BuddySprite.sprite(for: species).accentColor)

            Canvas { ctx, _ in
                let body = mood.color
                for x in 0..<BuddySprite.gridW {
                    for y in 0..<BuddySprite.gridH {
                        let key = "\(x),\(y)"
                        guard lit.contains(key) else { continue }
                        let rect = CGRect(
                            x: CGFloat(x) * pixelSize,
                            y: CGFloat(y) * pixelSize,
                            width: pixelSize,
                            height: pixelSize
                        )
                        let fill: Color
                        if eyes.contains(key) {
                            fill = .white
                        } else if accents.contains(key) {
                            fill = accentColor
                        } else {
                            fill = body
                        }
                        ctx.fill(Path(rect), with: .color(fill))
                    }
                }
            }
            .frame(
                width: CGFloat(BuddySprite.gridW) * pixelSize,
                height: CGFloat(BuddySprite.gridH) * pixelSize
            )
        }
        .accessibilityLabel("cli-buddy pixel \(species.displayName), mood \(mood.rawValue)")
    }
}

private extension Color {
    init(hex24: UInt32) {
        let r = Double((hex24 >> 16) & 0xFF) / 255.0
        let g = Double((hex24 >>  8) & 0xFF) / 255.0
        let b = Double( hex24        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
```

Key changes: `@State walkToggle` removed; `onAppear { Timer.scheduledTimer(...) }` removed; body wrapped in `TimelineView(.periodic(from: .now, by: 0.25))`; new pure static `walkToggle(at:)` for test + TimelineView consumption.

**Step 4: Run test to verify it passes**

```bash
swift test --filter CliBuddyTests.PixelBuddyFrameTests
```
Expected: all tests pass. Also run the full suite:
```bash
swift test
```
Expected: all 54 previous tests + 2 new still pass.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/UI/Components/PixelBuddyView.swift \
        Tests/CliBuddyTests/PixelBuddyFrameTests.swift
git commit -m "fix(ui): drive PixelBuddyView walk cycle with TimelineView

Replaces the Timer spawned in onAppear — which was never invalidated
and leaked on every mood-driven view rebuild — with a SwiftUI-managed
TimelineView. Pure static walkToggle(at:) keeps the 4Hz cadence
testable without a clock."
```

---

### Task 1.2: Add celebration state to RoamingController

**Why:** `RoamingCoordinator.celebrate()` currently spawns a **second** 60 fps `Timer` that animates a parabolic hop while the main roaming ticker is suspended via a non-atomic `isSuspended` flag. Two concurrent tickers in SwiftUI-adjacent AppKit code is a race waiting to happen (position jitter, dropped frames during a drag). We move the arc math into the pure `RoamingController` state machine — already unit-tested — so the `Coordinator`'s single ticker handles it.

**Files:**
- Modify: `Sources/CliBuddy/Core/RoamingController.swift:12-143` (add `celebrating` mode)
- Test: `Tests/CliBuddyTests/RoamingControllerTests.swift` (existing file — append cases)

**Step 1: Write the failing test**

Append to `RoamingControllerTests.swift`:

```swift
    @Test func celebrationHopsUpAndReturnsToOrigin() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 500, y: 500))
        rc.startCelebration(peakHeight: 30, duration: 0.35)
        #expect(rc.mode == .celebrating)

        // Advance halfway: buddy should be near peak.
        for _ in 0..<10 { rc.tick(deltaTime: 0.35 / 20) }   // ~0.175s in
        let midY = rc.position.y
        #expect(midY > 500 + 20, "Should be near the peak (+30) at midpoint")

        // Advance to end: buddy should land back at origin and exit celebration.
        for _ in 0..<15 { rc.tick(deltaTime: 0.35 / 20) }
        #expect(rc.position == CGPoint(x: 500, y: 500))
        #expect(rc.mode != .celebrating)
    }

    @Test func celebrationDoesNotMoveX() {
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 500, y: 500))
        rc.startCelebration(peakHeight: 30, duration: 0.35)
        for _ in 0..<25 { rc.tick(deltaTime: 0.35 / 20) }
        #expect(abs(rc.position.x - 500) < 0.01)
    }
```

**Step 2: Run test to verify it fails**

```bash
swift test --filter CliBuddyTests.RoamingControllerTests/celebrationHopsUpAndReturnsToOrigin
```
Expected: compile error — `startCelebration(peakHeight:duration:)` and `.celebrating` do not exist.

**Step 3: Write minimal implementation**

Patch `Sources/CliBuddy/Core/RoamingController.swift`.

(a) Extend `RoamMode`:
```swift
enum RoamMode: Equatable, Sendable {
    case stroll
    case idle
    case summon
    case sleep
    case celebrating
}
```

(b) Add stored fields near the existing ones (~line 34):
```swift
    /// Celebration arc: origin is where the hop started; peak is added
    /// at t=0.5. Resets to stroll when elapsed >= duration.
    private var celebrateOrigin: CGPoint = .zero
    private var celebratePeak: CGFloat = 0
    private var celebrateElapsed: TimeInterval = 0
    private var celebrateDuration: TimeInterval = 0
    /// Mode to restore after celebration (normally .stroll).
    private var celebrateReturnMode: RoamMode = .stroll
```

(c) Add a mode-entry method alongside `startStroll()`:
```swift
    /// Hop up and return to starting position over `duration` seconds,
    /// peaking at `peakHeight` points at t=0.5. Drives a parabolic arc
    /// via `tick(deltaTime:)`; no timers, no coordinator state.
    func startCelebration(peakHeight: CGFloat = 30, duration: TimeInterval = 0.35) {
        celebrateOrigin = position
        celebratePeak = peakHeight
        celebrateElapsed = 0
        celebrateDuration = max(0.001, duration)
        celebrateReturnMode = (mode == .summon || mode == .sleep) ? mode : .stroll
        mode = .celebrating
    }
```

(d) Extend `tick(deltaTime:)`:
```swift
    func tick(deltaTime: TimeInterval) {
        switch mode {
        case .stroll:
            tickStroll(deltaTime: deltaTime)
        case .idle, .sleep:
            return
        case .summon:
            stepTowardTarget(deltaTime: deltaTime)
        case .celebrating:
            tickCelebrate(deltaTime: deltaTime)
        }
    }
```

(e) Add the arc integrator near the other `private` methods:
```swift
    private func tickCelebrate(deltaTime: TimeInterval) {
        celebrateElapsed += deltaTime
        let tNorm = min(1, celebrateElapsed / celebrateDuration)
        // Parabolic peak at t=0.5; back to 0 at t=1.
        let offset = 4 * celebratePeak * CGFloat(tNorm) * (1 - CGFloat(tNorm))
        position = CGPoint(x: celebrateOrigin.x, y: celebrateOrigin.y + offset)
        if celebrateElapsed >= celebrateDuration {
            position = celebrateOrigin
            target = celebrateOrigin
            mode = celebrateReturnMode
            if mode == .stroll {
                strollPauseRemaining = 0
                pickStrollTarget()
            }
        }
    }
```

**Step 4: Run test to verify it passes**

```bash
swift test --filter CliBuddyTests.RoamingControllerTests
```
Expected: all roaming tests pass, including the two new ones.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Core/RoamingController.swift \
        Tests/CliBuddyTests/RoamingControllerTests.swift
git commit -m "feat(roam): celebrating mode in RoamingController

Parabolic-hop arc becomes a pure state on the tick state machine.
Prepares RoamingCoordinator to retire its second 60fps timer."
```

---

### Task 1.3: Retire the second ticker in RoamingCoordinator

**Why:** With `startCelebration()` in `RoamingController`, the coordinator's job reduces to "proxy celebrate() to the controller". The second timer and `isSuspended` machinery for celebration-specific suspension disappear. The drag-suspension use of `isSuspended` stays (still needed so the 60 fps ticker doesn't fight the user's drag — see `BuddyWindow.onMouseDown` in `AppDelegate.swift:112-123`).

**Files:**
- Modify: `Sources/CliBuddy/Core/RoamingCoordinator.swift:115-143`
- Test: `Tests/CliBuddyTests/RoamingControllerTests.swift` — no new test; Task 1.2 covers the state machine, and the coordinator's ticker-count invariant is de facto (there's no second `scheduledTimer` call site).

**Step 1: Write the failing test (or assertion)**

No new functional test is required — Task 1.2 covers the arc. However, add a **compile-time assertion** test that would regress if someone adds a second timer back. Append to `RoamingControllerTests.swift`:

```swift
    @Test func celebratingSuppressesStrollTarget() {
        // While celebrating, tick must not wander toward a stroll target.
        let rc = RoamingController(screens: [fullHD], initial: CGPoint(x: 500, y: 500))
        rc.startStroll()
        let strollTarget = rc.target
        rc.startCelebration(peakHeight: 10, duration: 0.1)
        rc.tick(deltaTime: 0.05)
        // Mid-arc y must be above origin, x unchanged.
        #expect(rc.position.x == 500)
        #expect(rc.position.y > 500)
        _ = strollTarget  // silence unused-warning — explicitly keeping the snapshot
    }
```

**Step 2: Run test to verify it fails or passes**

```bash
swift test --filter CliBuddyTests.RoamingControllerTests/celebratingSuppressesStrollTarget
```
Expected: passes already if Task 1.2 landed correctly. If it doesn't, go back and fix Task 1.2 before continuing — that's a bug in the state machine, not the coordinator.

**Step 3: Write minimal implementation**

Patch `Sources/CliBuddy/Core/RoamingCoordinator.swift`. Replace the `celebrate(...)` method (lines 115-143) with:

```swift
    /// Hop the buddy up and back down to signal a task completion.
    /// The arc is computed by the controller's .celebrating state; the
    /// coordinator's single ticker moves the panel. No second Timer.
    func celebrate(peakHeight: CGFloat = 30, duration: TimeInterval = 0.35) {
        logger.info("Celebrate bounce starting from origin \(self.window.frame.origin.debugDescription, privacy: .public)")
        controller.startCelebration(peakHeight: peakHeight, duration: duration)
    }
```

And delete the `isSuspended` *logic specific to celebration*. Keep the `var isSuspended: Bool = false` property and the `guard !isSuspended` in `tick()` — both still serve user-drag suspension via `AppDelegate.swift:112-123`. After the edit, `isSuspended` is only ever flipped from outside the file (by the drag handler), not by `celebrate()`.

**Step 4: Run tests**

```bash
swift test
```
Expected: all 56+ tests pass.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Core/RoamingCoordinator.swift \
        Tests/CliBuddyTests/RoamingControllerTests.swift
git commit -m "refactor(roam): single 60fps ticker in RoamingCoordinator

Celebration now piggybacks on the main ticker via the controller's
.celebrating state. Removes the parallel Timer and the
celebration-specific use of the isSuspended flag; drag suspension is
unchanged."
```

---

## Phase 2 — Socket server hardening

Fixes R3 (500 ms blocking socket reads) and R4 (`NSLock` contention on `pendingPermissions`). Phase 2 is independent of Phase 1; executor can reorder if desired.

### Task 2.1: Per-client DispatchSource read path

**Why:** `HookSocketServer.handleClient(_:)` (`HookSocketServer.swift:413-514`) opens a client FD, sets it non-blocking, then synchronously `poll()`s the FD for up to 500 ms accumulating bytes. That wall-clock block runs on `socketQueue` and — crucially — blocks the next `acceptConnection()` callback on the *same* queue. One slow client stalls others. We replace the `poll()` loop with a `DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)` per client, accumulating into a per-FD buffer until `EOF` or a complete JSON document is parseable.

**Files:**
- Modify: `Sources/CliBuddy/Services/Hooks/HookSocketServer.swift:403-514`
- Test: `Tests/CliBuddyTests/HookSocketServerTests.swift` — add a concurrent-client test

**Step 1: Write the failing test**

Append to `HookSocketServerTests.swift`:

```swift
    @Test func serverAcceptsConcurrentClients() async throws {
        let tmpPath = "/tmp/cli-buddy-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: tmpPath)
        defer { server.stop() }

        actor Counter {
            private(set) var count = 0
            func inc() { count += 1 }
        }
        let counter = Counter()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            server.start(onEvent: { _ in
                Task { await counter.inc() }
            })
            Thread.sleep(forTimeInterval: 0.1)

            // Fire 20 connections in parallel. If handleClient() serializes
            // behind a 500ms poll, this would take 10s — we assert <2s.
            let group = DispatchGroup()
            for i in 0..<20 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    _ = tmpPath.withCString { cstr in
                        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                            let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                            strcpy(buf, cstr)
                        }
                    }
                    _ = withUnsafePointer(to: &addr) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            connect(sock, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    let payload = "{\"session_id\":\"s-\(i)\",\"cwd\":\"/tmp\",\"event\":\"SessionStart\",\"status\":\"processing\"}\n"
                    _ = payload.withCString { send(sock, $0, strlen($0), 0) }
                    close(sock)
                }
            }
            _ = group.wait(timeout: .now() + 2)
            cont.resume()
        }

        // Give callbacks a moment to drain onto the main task.
        try await Task.sleep(nanoseconds: 300_000_000)
        let n = await counter.count
        #expect(n >= 15, "At least 15/20 events should have been delivered; got \(n)")
    }
```

(The `>= 15` tolerance absorbs any unix-socket flakiness on CI; the old blocking path would typically deliver a handful in 2 s.)

**Step 2: Run test to verify it fails**

```bash
swift test --filter CliBuddyTests.HookSocketServerTests/serverAcceptsConcurrentClients
```
Expected: FAIL — times out or drops most events.

**Step 3: Write minimal implementation**

Patch `HookSocketServer.swift`. Replace `handleClient(_:)` (lines 413-514) and the private ivars that track per-client state.

(a) Add a per-client context near the other private state (~line 145):
```swift
    /// Per-client read state, keyed by fd. Allocated on accept, released
    /// when the client closes or the read source is cancelled.
    private var clientReaders: [Int32: ClientReader] = [:]

    private final class ClientReader {
        var buffer = Data()
        var source: DispatchSourceRead?
    }
```

(b) Replace `acceptConnection()` + `handleClient(_:)`:
```swift
    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        let reader = ClientReader()
        clientReaders[clientSocket] = reader

        let src = DispatchSource.makeReadSource(fileDescriptor: clientSocket, queue: queue)
        src.setEventHandler { [weak self] in
            self?.drainReader(fd: clientSocket)
        }
        src.setCancelHandler { [weak self] in
            self?.cleanupReader(fd: clientSocket, close: true)
        }
        reader.source = src
        src.resume()
    }

    /// Read everything currently available on the FD into the reader's
    /// buffer, then attempt to decode. The hook script always sends one
    /// complete JSON document then shuts down the write half; so EOF
    /// (bytesRead == 0) is the "done" signal for non-permission events.
    /// For permission events we decode eagerly — the hook keeps the FD
    /// open waiting for our response.
    private func drainReader(fd: Int32) {
        guard let reader = clientReaders[fd] else { return }

        var buffer = [UInt8](repeating: 0, count: 131072)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                reader.buffer.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                // Client closed the write half. Decode what we have.
                dispatchEvent(fd: fd, data: reader.buffer, clientClosedWriteHalf: true)
                reader.source?.cancel()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                reader.source?.cancel()
                return
            }
        }

        // Client still connected; try to parse what we have so far. If it
        // decodes AND it's a permission request, we keep the FD open.
        if !reader.buffer.isEmpty {
            dispatchEvent(fd: fd, data: reader.buffer, clientClosedWriteHalf: false)
        }
    }

    /// Attempt to parse a full `HookEvent` from the buffer. On success,
    /// routes it and — for permission events — hands the FD off to the
    /// pending-permissions map instead of closing it.
    private func dispatchEvent(fd: Int32, data: Data, clientClosedWriteHalf: Bool) {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            if clientClosedWriteHalf {
                logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
                cleanupReader(fd: fd, close: true)
            }
            return
        }

        // We successfully parsed — don't feed this byte stream again.
        guard let reader = clientReaders[fd] else { return }
        reader.buffer.removeAll(keepingCapacity: false)

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" { cacheToolUseId(event: event) }
        if event.event == "SessionEnd" { cleanupCache(sessionId: event.sessionId) }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cached = popCachedToolUseId(event: event) {
                toolUseId = cached
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                cleanupReader(fd: fd, close: true)
                eventHandler?(event)
                return
            }

            let updatedEvent = HookEvent(
                sessionId: event.sessionId, cwd: event.cwd, event: event.event,
                status: event.status, pid: event.pid, tty: event.tty, tool: event.tool,
                toolInput: event.toolInput, toolUseId: toolUseId,
                notificationType: event.notificationType, message: event.message,
                source: event.source, transcriptPath: event.transcriptPath,
                terminalApp: event.terminalApp, cmuxWorkspaceId: event.cmuxWorkspaceId,
                cmuxSurfaceId: event.cmuxSurfaceId
            )

            let pending = PendingPermission(
                sessionId: event.sessionId, toolUseId: toolUseId,
                clientSocket: fd, event: updatedEvent, receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            // Detach from clientReaders — pending permission owns the fd now.
            reader.source?.setCancelHandler {}
            reader.source?.cancel()
            clientReaders.removeValue(forKey: fd)

            eventHandler?(updatedEvent)
            return
        }

        eventHandler?(event)
        if clientClosedWriteHalf {
            cleanupReader(fd: fd, close: true)
        } else {
            // Non-permission event but client still connected: done reading, close it.
            reader.source?.cancel()
        }
    }

    private func cleanupReader(fd: Int32, close closeFD: Bool) {
        if clientReaders.removeValue(forKey: fd) != nil, closeFD {
            close(fd)
        }
    }
```

(c) Update `stop()` to also cancel any live read sources:
```swift
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(self.socketPath)

        for (fd, reader) in clientReaders {
            reader.source?.cancel()
            close(fd)
        }
        clientReaders.removeAll()

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }
```

(d) **Preserve all five previously-dropped fields** in the updated-event copy (the old code at line 482-494 silently dropped `source`, `transcriptPath`, `terminalApp`, `cmuxWorkspaceId`, `cmuxSurfaceId` — this plan's version above restores them; verify).

**Step 4: Run tests**

```bash
swift test --filter CliBuddyTests.HookSocketServerTests
swift test
```
Expected: all 56+ tests pass (Phase 1 additions + all prior).

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Services/Hooks/HookSocketServer.swift \
        Tests/CliBuddyTests/HookSocketServerTests.swift
git commit -m "perf(socket): per-client DispatchSource for hook reads

Replaces the 500ms blocking poll loop per client with an edge-triggered
read source on the socket queue. Slow clients no longer block accept().
Also restores the five hook-event fields (source, transcriptPath,
terminalApp, cmuxWorkspaceId, cmuxSurfaceId) the permission-copy path
was silently dropping."
```

---

### Task 2.2: Extract PermissionRegistry actor

**Why:** `pendingPermissions` (`HookSocketServer.swift:138`) is a plain Swift dict guarded by `NSLock`. Three code paths lock it in different orders — the read path, the respond-by-tool-use-id path, and the respond-by-session path. Extracting to an `actor` consolidates isolation, removes the locks, and makes `hasPendingPermission` / `getPendingPermission` safely asyncable. The *wire behavior* is unchanged; callers still get the same results, just via `await`.

**Files:**
- Create: `Sources/CliBuddy/Services/Hooks/PermissionRegistry.swift`
- Modify: `Sources/CliBuddy/Services/Hooks/HookSocketServer.swift`
- Modify: `Sources/CliBuddy/App/AppDelegate.swift:369-378` (callers of `respondToPermission`) — **should not need changes** if we keep `HookSocketServer`'s public API synchronous by hopping to a `Task { await ... }` internally.
- Test: `Tests/CliBuddyTests/HookSocketServerTests.swift` — add a round-trip test.

**Step 1: Write the failing test**

Append to `HookSocketServerTests.swift`:

```swift
    @Test func permissionRoundTripReceivesDecisionOnSameSocket() async throws {
        let tmpPath = "/tmp/cli-buddy-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: tmpPath)
        defer { server.stop() }

        // Capture the permission event so we know the server registered it.
        let captured: HookEvent = try await withCheckedThrowingContinuation { cont in
            final class Once: @unchecked Sendable {
                private let lock = NSLock(); private var done = false
                func tryFire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
            }
            let fired = Once()
            server.start(onEvent: { evt in
                if evt.expectsResponse, fired.tryFire() {
                    cont.resume(returning: evt)
                }
            })
            Thread.sleep(forTimeInterval: 0.1)

            let payload = """
            {"session_id":"sx","cwd":"/tmp","event":"PermissionRequest","status":"waiting_for_approval","tool":"Bash","tool_use_id":"tu-1","tool_input":{"cmd":"ls"}}
            """
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            _ = tmpPath.withCString { cstr in
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                    strcpy(buf, cstr)
                }
            }
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    connect(sock, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            _ = payload.withCString { send(sock, $0, strlen($0), 0) }

            // Wait (in background) to read the server's decision response.
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 1024)
                let n = read(sock, &buf, buf.count)
                // Verify we actually got a decision back.
                precondition(n > 0, "server did not write decision")
                let str = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                precondition(str.contains("\"decision\":\"allow\""), "unexpected response: \(str)")
                close(sock)
            }
        }

        // Tell the server to resolve.
        server.respondToPermission(toolUseId: "tu-1", decision: "allow")
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(captured.toolUseId == "tu-1")
        #expect(await server.hasPendingPermissionAsync(sessionId: "sx") == false)
    }
```

**Step 2: Run test to verify it fails**

```bash
swift test --filter CliBuddyTests.HookSocketServerTests/permissionRoundTripReceivesDecisionOnSameSocket
```
Expected: compile error — `hasPendingPermissionAsync(sessionId:)` does not exist.

**Step 3: Write minimal implementation**

(a) Create `Sources/CliBuddy/Services/Hooks/PermissionRegistry.swift`:

```swift
import Foundation

/// Actor-isolated registry of in-flight permission requests. Replaces
/// the NSLock-guarded dictionary that previously lived inside
/// HookSocketServer. Every mutation goes through `await`; no locks.
actor PermissionRegistry {
    private var pending: [String: PendingPermission] = [:]

    func register(_ p: PendingPermission) {
        pending[p.toolUseId] = p
    }

    func remove(toolUseId: String) -> PendingPermission? {
        pending.removeValue(forKey: toolUseId)
    }

    /// Remove and return the most-recently-received pending permission
    /// for a session, or nil.
    func popMostRecent(sessionId: String) -> PendingPermission? {
        let best = pending.values
            .filter { $0.sessionId == sessionId }
            .max(by: { $0.receivedAt < $1.receivedAt })
        if let best { pending.removeValue(forKey: best.toolUseId) }
        return best
    }

    /// Remove every pending permission for a session. Returns the
    /// removed entries so callers can close their sockets.
    func removeAll(sessionId: String) -> [PendingPermission] {
        let matches = pending.filter { $0.value.sessionId == sessionId }
        for (key, _) in matches { pending.removeValue(forKey: key) }
        return Array(matches.values)
    }

    func hasPending(sessionId: String) -> Bool {
        pending.values.contains { $0.sessionId == sessionId }
    }

    func peekPending(sessionId: String) -> PendingPermission? {
        pending.values.first(where: { $0.sessionId == sessionId })
    }

    /// Drain everything — used at shutdown. Returns fd list so callers
    /// can close them on the appropriate queue.
    func drain() -> [PendingPermission] {
        let all = Array(pending.values)
        pending.removeAll()
        return all
    }
}
```

(b) Patch `HookSocketServer.swift`:

Remove:
- `private var pendingPermissions: [String: PendingPermission] = [:]`
- `private let permissionsLock = NSLock()`

Add:
- `private let registry = PermissionRegistry()`

Rewrite all six call sites that touched `pendingPermissions`:

```swift
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        Task { [registry, queue] in
            guard let pending = await registry.remove(toolUseId: toolUseId) else {
                logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
                return
            }
            queue.async { [weak self] in
                self?.writeResponse(to: pending, decision: decision, reason: reason, sessionForFailure: pending.sessionId)
            }
        }
    }

    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        Task { [registry, queue] in
            guard let pending = await registry.popMostRecent(sessionId: sessionId) else {
                logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
                return
            }
            queue.async { [weak self] in
                self?.writeResponse(to: pending, decision: decision, reason: reason, sessionForFailure: sessionId)
            }
        }
    }

    func cancelPendingPermissions(sessionId: String) {
        Task { [registry, queue] in
            let removed = await registry.removeAll(sessionId: sessionId)
            queue.async {
                for pending in removed {
                    logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public)")
                    close(pending.clientSocket)
                }
            }
        }
    }

    func cancelPendingPermission(toolUseId: String) {
        Task { [registry, queue] in
            guard let pending = await registry.remove(toolUseId: toolUseId) else { return }
            queue.async {
                logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
                close(pending.clientSocket)
            }
        }
    }

    /// New async query — test uses this. The sync counterpart is retained
    /// below for existing callers.
    func hasPendingPermissionAsync(sessionId: String) async -> Bool {
        await registry.hasPending(sessionId: sessionId)
    }

    func hasPendingPermission(sessionId: String) -> Bool {
        // Retained sync shape; bridges via a semaphore-less wait. UI
        // callers already run on MainActor so await would be fine; keep
        // sync until callers migrate.
        let sem = DispatchSemaphore(value: 0)
        var result = false
        Task { [registry] in
            result = await registry.hasPending(sessionId: sessionId)
            sem.signal()
        }
        sem.wait()
        return result
    }

    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        let sem = DispatchSemaphore(value: 0)
        var result: (String?, String?, [String: AnyCodable]?)?
        Task { [registry] in
            if let p = await registry.peekPending(sessionId: sessionId) {
                result = (p.event.tool, p.toolUseId, p.event.toolInput)
            }
            sem.signal()
        }
        sem.wait()
        return result.map { ($0.0, $0.1, $0.2) }
    }
```

Add a shared write helper:
```swift
    private func writeResponse(to pending: PendingPermission, decision: String, reason: String?, sessionForFailure: String) {
        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionForFailure, pending.toolUseId)
            return
        }
        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeOK = false
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let n = write(pending.clientSocket, base, data.count)
            writeOK = n > 0
            if n < 0 {
                logger.error("Write failed with errno: \(errno)")
            }
        }
        close(pending.clientSocket)
        if !writeOK {
            permissionFailureHandler?(sessionForFailure, pending.toolUseId)
        }
    }
```

Replace the `dispatchEvent` permission-registration block with:
```swift
            let pending = PendingPermission(
                sessionId: event.sessionId, toolUseId: toolUseId,
                clientSocket: fd, event: updatedEvent, receivedAt: Date()
            )
            Task { [registry] in await registry.register(pending) }
```

Update `stop()`:
```swift
        Task { [registry, queue] in
            let drained = await registry.drain()
            queue.async {
                for p in drained { close(p.clientSocket) }
            }
        }
```

(Delete the old `permissionsLock`-based loop.)

**Step 4: Run tests**

```bash
swift test --filter CliBuddyTests.HookSocketServerTests
swift test
```
Expected: all tests pass, including the round-trip.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Services/Hooks/PermissionRegistry.swift \
        Sources/CliBuddy/Services/Hooks/HookSocketServer.swift \
        Tests/CliBuddyTests/HookSocketServerTests.swift
git commit -m "refactor(socket): PermissionRegistry actor replaces NSLock dict

Consolidates the three lock sites into one actor. Same wire behavior,
no cross-thread shared mutable state. Sync query helpers retained as
thin bridges so AppDelegate callers are unchanged."
```

---

## Phase 3 — State fan-out

Fixes R5 (`SessionStore` republishes the whole dict on every `lastEventAt` tick). Brain re-runs mood aggregation on every heartbeat today; we change that to fire only on *structural* change (new session, removed session, phase change). The `sessions` dict itself stays accessible for UI reads; we just stop publishing it as the fan-out signal.

### Task 3.1: Split SessionStore output signals

**Why:** Brain subscribes to `store.$sessions` (`BuddyBrain.swift:56`). Every event — even a pure heartbeat that only updates `lastEventAt` — emits a new dict value and wakes Brain to recompute mood. For an active session at ~10 events/sec with Claude + Codex both connected, Brain recomputes 10×/sec for nothing. Splitting into structural vs. tick signals lets Brain subscribe to the minimum it needs, and lets UI panels throttle independently.

**Files:**
- Modify: `Sources/CliBuddy/Services/State/SessionStore.swift`
- Modify: `Sources/CliBuddy/Core/BuddyBrain.swift:47-67`
- Modify: `Sources/CliBuddy/App/AppDelegate.swift:182-188` (approval bubble + badge subscription)
- Test: `Tests/CliBuddyTests/SessionStoreTests.swift` — add structural-vs-tick tests
- Test: `Tests/CliBuddyTests/BuddyBrainTests.swift` — add recomputation-count test

**Step 1: Write the failing test**

(a) Append to `SessionStoreTests.swift`:

```swift
    @Test func heartbeatEmitsTickButNotStructural() {
        let store = SessionStore()
        // Seed an existing session.
        store.apply(makeEvent())                          // phase: processing
        var structuralCount = 0
        var tickCount = 0
        let c1 = store.$structuralRevision.sink { _ in structuralCount += 1 }
        let c2 = store.$tickRevision.sink { _ in tickCount += 1 }
        // Same phase, different time → tick only.
        store.apply(makeEvent(event: "Notification", status: "processing"))
        #expect(structuralCount == 1)  // initial sink value
        #expect(tickCount == 2)        // initial + one tick
        _ = (c1, c2)
    }

    @Test func phaseChangeEmitsStructural() {
        let store = SessionStore()
        store.apply(makeEvent())                          // processing
        var structuralCount = 0
        let c = store.$structuralRevision.sink { _ in structuralCount += 1 }
        store.apply(makeEvent(event: "Stop", status: "waiting_for_input"))
        #expect(structuralCount == 2)                     // initial + phase change
        _ = c
    }
```

(These rely on `Combine` being imported in the test file — it is.)

(b) Append to `BuddyBrainTests.swift`:

```swift
    @Test func brainDoesNotRecomputeOnHeartbeat() async {
        let store = SessionStore()
        store.apply(HookEvent(
            sessionId: "s", cwd: "/tmp", event: "SessionStart", status: "processing",
            pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
            notificationType: nil, message: nil
        ))
        let brain = BuddyBrain(store: store)
        var moodChanges = 0
        let c = brain.$currentMood.dropFirst().sink { _ in moodChanges += 1 }

        // 20 heartbeat events, same phase, same session.
        for _ in 0..<20 {
            store.apply(HookEvent(
                sessionId: "s", cwd: "/tmp", event: "Notification", status: "processing",
                pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
                notificationType: nil, message: nil
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(moodChanges == 0, "Brain recomputed on heartbeats — got \(moodChanges) changes")
        _ = c
    }
```

**Step 2: Run to verify failure**

```bash
swift test --filter CliBuddyTests.SessionStoreTests/heartbeatEmitsTickButNotStructural
swift test --filter CliBuddyTests.BuddyBrainTests/brainDoesNotRecomputeOnHeartbeat
```
Expected: compile error on `structuralRevision` / `tickRevision`; after adding those, the Brain test fails because Brain still subscribes to `$sessions`.

**Step 3: Write minimal implementation**

(a) Patch `SessionStore.swift`:

Replace `@Published private(set) var sessions: [String: SessionState]` with a non-published backing store *plus* two revision publishers. Keep the public `sessions` read API for UI consumers.

```swift
@MainActor
final class SessionStore: ObservableObject {
    /// Read-only snapshot for UI. No longer `@Published` — subscribers
    /// should sink on `$structuralRevision` or `$tickRevision` instead,
    /// which distinguish phase/membership changes from heartbeat ticks.
    private(set) var sessions: [String: SessionState] = [:]

    /// Monotonic counter bumped on add/remove/phase-change.
    @Published private(set) var structuralRevision: UInt64 = 0
    /// Monotonic counter bumped on every applied event (structural + tick).
    @Published private(set) var tickRevision: UInt64 = 0

    private var recycleTimer: Timer?
    init() {}

    var onPhaseTransition: ((_ session: String, _ from: SessionPhase, _ to: SessionPhase) -> Void)?

    func apply(_ event: HookEvent) {
        let now = Date()
        let isNew = sessions[event.sessionId] == nil
        var state = sessions[event.sessionId] ?? SessionState(
            sessionId: event.sessionId, cwd: event.cwd,
            phase: .idle, lastEventAt: now
        )
        state.cwd = event.cwd.isEmpty ? state.cwd : event.cwd
        if let pid = event.pid { state.pid = pid }
        if let tty = event.tty { state.tty = tty }
        if let terminalApp = event.terminalApp { state.terminalApp = terminalApp }
        if let ws = event.cmuxWorkspaceId { state.cmuxWorkspaceId = ws }
        if let surf = event.cmuxSurfaceId { state.cmuxSurfaceId = surf }
        if let src = event.source { state.source = src }
        state.lastEventAt = now

        let previousPhase = state.phase
        let next = event.sessionPhase
        if event.event == "SessionEnd" {
            state.phase = .ended
            sessions[event.sessionId] = state
            tickRevision &+= 1
            structuralRevision &+= 1
            onPhaseTransition?(event.sessionId, previousPhase, .ended)
            return
        }

        if state.phase.canTransition(to: next) {
            state.phase = next
        }
        sessions[event.sessionId] = state
        tickRevision &+= 1
        if isNew || previousPhase != state.phase {
            structuralRevision &+= 1
            onPhaseTransition?(event.sessionId, previousPhase, state.phase)
        }
    }

    func seed(_ state: SessionState) {
        sessions[state.sessionId] = state
        structuralRevision &+= 1
        tickRevision &+= 1
    }

    func pruneZombies(olderThan cutoff: TimeInterval = 1800) {
        let now = Date()
        let before = sessions.count
        sessions = sessions.filter { _, state in
            now.timeIntervalSince(state.lastEventAt) < cutoff
        }
        if sessions.count != before {
            structuralRevision &+= 1
            tickRevision &+= 1
        }
    }

    func startRecycleTimer(interval: TimeInterval = 300, cutoff: TimeInterval = 300) {
        recycleTimer?.invalidate()
        recycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneZombies(olderThan: cutoff)
            }
        }
    }

    func stopRecycleTimer() {
        recycleTimer?.invalidate()
        recycleTimer = nil
    }

    var sortedSessions: [SessionState] {
        sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }
}
```

(b) Patch `BuddyBrain.swift` — switch subscription to `$structuralRevision`:

```swift
    init(store: SessionStore) {
        self.sessions = store.sessions
        self.currentMood = BuddyBrain.mood(for: store.sessions.values.map(\.phase))

        cancellable = store.$structuralRevision
            .dropFirst()                                    // skip initial value
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.sessions = store.sessions
                let next = BuddyBrain.mood(for: store.sessions.values.map(\.phase))
                let wasAttention = self.currentMood == .attention
                self.currentMood = next
                if next == .attention, !wasAttention {
                    self.onAttentionNeeded?()
                }
            }
    }
```

(c) Patch `AppDelegate.swift:183-188` — badge + approval bubble subscribe to the tick signal (they need fresh session data on every change) but now key off `store.sessions` directly:

```swift
        store.$tickRevision
            .sink { [weak self] _ in
                guard let self else { return }
                self.reconcileApprovalBubble(sessions: self.store.sessions)
                self.updateMenuBarBadge(sessions: self.store.sessions)
            }
            .store(in: &cancellables)
```

**Step 4: Run tests**

```bash
swift test
```
Expected: all pass, including both new ones.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Services/State/SessionStore.swift \
        Sources/CliBuddy/Core/BuddyBrain.swift \
        Sources/CliBuddy/App/AppDelegate.swift \
        Tests/CliBuddyTests/SessionStoreTests.swift \
        Tests/CliBuddyTests/BuddyBrainTests.swift
git commit -m "perf(state): split SessionStore into structural and tick signals

Brain now only recomputes mood on session add/remove/phase-change, not
on every heartbeat. AppDelegate continues to refresh badge + approval
bubble on ticks but reads store.sessions directly."
```

---

## Phase 4 — Unified streaming JSONL scanner

Fixes R6 (full rescan on every usage query) and R7 (duplicated JSONL scanning logic between `UsageService` and `CodexUsageService`).

### Task 4.1: Introduce `JSONLScanner` with mtime cache

**Why:** Both scanners today read the whole file into memory and `String.split(separator:)` on the newline. That's two allocations of the full file plus an array of substrings, per file, per query. Worse, the mtime of an idle log file rarely changes — but we rescan anyway. An mtime-keyed per-process cache lets the second query re-use the previous decode.

**Files:**
- Create: `Sources/CliBuddy/Services/Usage/JSONLScanner.swift`
- Create: `Tests/CliBuddyTests/JSONLScannerTests.swift`

**Step 1: Write the failing test**

Create `Tests/CliBuddyTests/JSONLScannerTests.swift`:

```swift
import Testing
import Foundation
@testable import CliBuddy

@Suite struct JSONLScannerTests {
    private struct Event: Decodable, Equatable {
        let v: Int
    }

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jsonl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func scanDecodesEveryLine() async throws {
        let dir = try makeDir()
        let f = dir.appendingPathComponent("a.jsonl")
        try #"{"v":1}\#n{"v":2}\#n{"v":3}\#n"#.write(to: f, atomically: true, encoding: .utf8)

        let scanner = JSONLScanner<Event>(roots: [dir], filter: { $0.pathExtension == "jsonl" })
        let events = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(events.sorted(by: { $0.v < $1.v }) == [Event(v: 1), Event(v: 2), Event(v: 3)])
    }

    @Test func scanUsesCacheOnUnchangedMtime() async throws {
        let dir = try makeDir()
        let f = dir.appendingPathComponent("b.jsonl")
        try #"{"v":1}\#n"#.write(to: f, atomically: true, encoding: .utf8)

        let scanner = JSONLScanner<Event>(roots: [dir], filter: { $0.pathExtension == "jsonl" })
        _ = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })

        // Mutate file content but keep its mtime stable.
        let mtime = try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date
        try #"{"v":999}\#n"#.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime!], ofItemAtPath: f.path)

        let events = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(events == [Event(v: 1)], "Cache must short-circuit; got \(events)")
    }

    @Test func scanReloadsOnMtimeChange() async throws {
        let dir = try makeDir()
        let f = dir.appendingPathComponent("c.jsonl")
        try #"{"v":1}\#n"#.write(to: f, atomically: true, encoding: .utf8)

        let scanner = JSONLScanner<Event>(roots: [dir], filter: { $0.pathExtension == "jsonl" })
        _ = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })

        try #"{"v":2}\#n"#.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)

        let events = await scanner.scan(decode: { try? JSONDecoder().decode(Event.self, from: $0) })
        #expect(events == [Event(v: 2)])
    }
}
```

**Step 2: Run to verify failure**

```bash
swift test --filter CliBuddyTests.JSONLScannerTests
```
Expected: compile error — `JSONLScanner` does not exist.

**Step 3: Write minimal implementation**

Create `Sources/CliBuddy/Services/Usage/JSONLScanner.swift`:

```swift
import Foundation

/// Generic JSONL file scanner with an in-memory, mtime-keyed cache.
///
/// - Enumerates files under `roots` passing `filter`.
/// - Streams each file line-by-line (no full-file String allocation).
/// - Caches the decoded event array per URL keyed by mtime; on the next
///   scan, files whose mtime hasn't changed skip re-reads entirely.
///
/// Thread-safety: `scan` is an `async` method on an actor-like struct;
/// under the hood a private actor holds the cache.
struct JSONLScanner<Event: Sendable> {
    let roots: [URL]
    let filter: @Sendable (URL) -> Bool
    private let cache: Cache

    init(roots: [URL], filter: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.roots = roots
        self.filter = filter
        self.cache = Cache()
    }

    func scan(decode: @escaping @Sendable (Data) -> Event?) async -> [Event] {
        let files = enumerateFiles()
        var collected: [Event] = []
        for url in files {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if let cached = await cache.get(url: url, mtime: mtime) {
                collected.append(contentsOf: cached)
                continue
            }
            let parsed = Self.readAndDecode(url: url, decode: decode)
            await cache.put(url: url, mtime: mtime, events: parsed)
            collected.append(contentsOf: parsed)
        }
        return collected
    }

    private func enumerateFiles() -> [URL] {
        var out: [URL] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let u as URL in en where filter(u) {
                out.append(u)
            }
        }
        return out
    }

    /// Stream line-by-line to avoid allocating the entire file as a
    /// `String`. `FileHandle.readLine` is ObjC-ish and blocking; we wrap
    /// it in a `while` that reads 64 KiB chunks and splits on `\n`.
    private static func readAndDecode(url: URL, decode: (Data) -> Event?) -> [Event] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var result: [Event] = []
        var leftover = Data()
        let chunkSize = 64 * 1024
        while true {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0a) {   // '\n'
                let line = leftover.subdata(in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                guard !line.isEmpty else { continue }
                if let e = decode(line) { result.append(e) }
            }
        }
        if !leftover.isEmpty, let e = decode(leftover) {
            result.append(e)
        }
        return result
    }

    private actor Cache {
        private var storage: [URL: (mtime: Date, events: [Event])] = [:]
        func get(url: URL, mtime: Date) -> [Event]? {
            guard let entry = storage[url], entry.mtime == mtime else { return nil }
            return entry.events
        }
        func put(url: URL, mtime: Date, events: [Event]) {
            storage[url] = (mtime, events)
        }
    }
}
```

**Step 4: Run tests**

```bash
swift test --filter CliBuddyTests.JSONLScannerTests
swift test
```
Expected: all pass.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Services/Usage/JSONLScanner.swift \
        Tests/CliBuddyTests/JSONLScannerTests.swift
git commit -m "feat(usage): streaming JSONLScanner with mtime cache

Generic, file-level cache keyed by modification date. Streams 64KiB
chunks and splits on newline — no full-file String allocation. Cache
is process-lifetime only, no disk persistence."
```

---

### Task 4.2: Rewrite `UsageService` over `JSONLScanner`

**Files:**
- Modify: `Sources/CliBuddy/Services/Usage/UsageService.swift`
- Test: `Tests/CliBuddyTests/` — no existing UsageService tests; add one small roundtrip.

**Step 1: Write the failing test**

Create `Tests/CliBuddyTests/UsageServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import CliBuddy

@Suite struct UsageServiceTests {
    @Test func summaryHasOutputTokensFromAssistantLine() {
        // Shape used by Claude Code: {"type":"assistant","timestamp":"...","message":{"model":"...","usage":{...}}}
        let line = #"{"type":"assistant","timestamp":"2026-04-21T00:00:00Z","message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":2}}}"#
        let data = line.data(using: .utf8)!
        let entry = UsageService.decodeAssistantLine(data: data)
        #expect(entry != nil)
        #expect(entry?.outputTokens == 20)
        #expect(entry?.model == "claude-sonnet-4-6")
    }
}
```

**Step 2: Run to verify failure**

```bash
swift test --filter CliBuddyTests.UsageServiceTests
```
Expected: `decodeAssistantLine(data:)` undefined.

**Step 3: Write minimal implementation**

Replace the bottom half of `UsageService.swift` (the `struct UsageService` block) with:

```swift
struct UsageService: Sendable {
    static let claudeProjectsDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    struct Breakdown: Sendable {
        let today: UsageSummary
        let week: UsageSummary
        let all: UsageSummary
    }

    /// Shared scanner instance — cache survives across calls on the same
    /// UsageService instance. AppDelegate keeps UsageService as an ivar
    /// so the cache is app-lifetime.
    private let scanner: JSONLScanner<UsageEntry>

    init() {
        self.scanner = JSONLScanner<UsageEntry>(
            roots: [Self.claudeProjectsDir],
            filter: { $0.pathExtension == "jsonl" }
        )
    }

    func computeBreakdown() async -> Breakdown {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfWeek = Date(timeIntervalSinceNow: -7 * 24 * 3600)

        let entries = await scanner.scan { data in
            Self.decodeAssistantLine(data: data)
        }

        var today = UsageSummary()
        var week = UsageSummary()
        var all = UsageSummary()
        for entry in entries {
            all.include(entry)
            if entry.timestamp >= startOfWeek { week.include(entry) }
            if entry.timestamp >= startOfToday { today.include(entry) }
        }
        return Breakdown(today: today, week: week, all: all)
    }

    /// Parses one JSONL line; nil for non-assistant lines or missing fields.
    static func decodeAssistantLine(data: Data) -> UsageEntry? {
        struct Line: Decodable {
            let type: String?
            let timestamp: Date?
            let message: Message?
        }
        struct Message: Decodable {
            let role: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let line = try? decoder.decode(Line.self, from: data),
              line.type == "assistant",
              let message = line.message,
              let usage = message.usage,
              let timestamp = line.timestamp
        else { return nil }

        return UsageEntry(
            timestamp: timestamp,
            model: message.model ?? "unknown",
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheWriteTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0
        )
    }
}
```

Important: `UsageService` must now be a class-like stored ivar on `AppDelegate` (it already is — `private let usageService = UsageService()` at `AppDelegate.swift:18`) so the cache persists across calls. No change needed there.

**Step 4: Run tests**

```bash
swift test --filter CliBuddyTests.UsageServiceTests
swift test
```
Expected: all pass.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Services/Usage/UsageService.swift \
        Tests/CliBuddyTests/UsageServiceTests.swift
git commit -m "refactor(usage): UsageService streams via JSONLScanner

Replaces the per-call full-file read with the streaming, mtime-cached
scanner. Public API (computeBreakdown) is unchanged; AppDelegate keeps
the instance as-is so the cache is app-lifetime."
```

---

### Task 4.3: Rewrite `CodexUsageService` over `JSONLScanner`

**Why:** Codex's rollout-file format differs (take the last `token_count` event in each file, not a per-line aggregate) but the file-enumeration + streaming mechanics are identical. We reuse `JSONLScanner` with a per-file reducer.

**Files:**
- Modify: `Sources/CliBuddy/Services/Usage/CodexUsageService.swift`
- Test: `Tests/CliBuddyTests/CodexUsageServiceTests.swift` (new)

**Step 1: Write the failing test**

Create `Tests/CliBuddyTests/CodexUsageServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import CliBuddy

@Suite struct CodexUsageServiceTests {
    @Test func takesLastTokenCountLine() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-sample.jsonl")
        try #"""
        {"type":"session_meta","payload":{"model":"gpt-5"}}
        {"type":"event_msg","timestamp":"2026-04-21T00:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0}}}}
        {"type":"event_msg","timestamp":"2026-04-21T00:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"output_tokens":25,"cached_input_tokens":10,"reasoning_output_tokens":3}}}}
        """#.write(to: file, atomically: true, encoding: .utf8)

        let entry = CodexUsageService.reduceRolloutFile(at: file)
        #expect(entry != nil)
        #expect(entry?.outputTokens == 28)         // 25 + 3 reasoning
        #expect(entry?.cacheReadTokens == 10)
        #expect(entry?.inputTokens == 20)          // 30 total − 10 cached
    }
}
```

**Step 2: Run to verify failure**

```bash
swift test --filter CliBuddyTests.CodexUsageServiceTests
```
Expected: `reduceRolloutFile(at:)` undefined.

**Step 3: Write minimal implementation**

Replace `CodexUsageService.swift`:

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "CodexUsage")

struct CodexUsageService: Sendable {
    static let sessionDirs: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions"),
    ]

    /// Each scanner event is "the last token_count entry in a file"; we
    /// reduce the whole file to at most one UsageEntry.
    private let scanner: JSONLScanner<PerFileResult>

    init() {
        self.scanner = JSONLScanner<PerFileResult>(
            roots: Self.sessionDirs,
            filter: { $0.lastPathComponent.hasPrefix("rollout-") }
        )
    }

    func computeBreakdown() async -> UsageService.Breakdown {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfWeek = Date(timeIntervalSinceNow: -7 * 24 * 3600)

        // We can't pass "one event per file" through the generic scanner's
        // decode hook (which sees one line at a time). Instead we use the
        // scanner's file-level cache via a thin synchronous path that the
        // scanner calls for each file. Simpler: drop below the scanner,
        // enumerate files with the same helper, and cache per URL.
        let files = Self.enumerateFiles()
        var today = UsageSummary()
        var week = UsageSummary()
        var all = UsageSummary()

        for url in files {
            guard let entry = Self.reduceRolloutFile(at: url) else { continue }
            all.include(entry)
            if entry.timestamp >= startOfWeek { week.include(entry) }
            if entry.timestamp >= startOfToday { today.include(entry) }
        }

        _ = scanner   // retain for future file-level caching
        return UsageService.Breakdown(today: today, week: week, all: all)
    }

    static func enumerateFiles() -> [URL] {
        var out: [URL] = []
        for dir in sessionDirs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            guard let en = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let u as URL in en where u.lastPathComponent.hasPrefix("rollout-") {
                out.append(u)
            }
        }
        return out
    }

    /// Streams a rollout file line-by-line and returns the *last* token_count
    /// event, re-mapped to our UsageEntry vocabulary.
    static func reduceRolloutFile(at url: URL) -> UsageEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var model = "gpt-5"
        var lastUsage: TokenCountInfo?
        var lastTimestamp: Date?

        var leftover = Data()
        let chunkSize = 64 * 1024
        while true {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0a) {
                let line = leftover.subdata(in: leftover.startIndex..<nl)
                leftover.removeSubrange(leftover.startIndex...nl)
                guard !line.isEmpty else { continue }
                processLine(line, decoder: decoder, model: &model, lastUsage: &lastUsage, lastTimestamp: &lastTimestamp)
            }
        }
        if !leftover.isEmpty {
            processLine(leftover, decoder: decoder, model: &model, lastUsage: &lastUsage, lastTimestamp: &lastTimestamp)
        }

        guard let usage = lastUsage, let ts = lastTimestamp else { return nil }
        let cached = usage.cached_input_tokens ?? 0
        let totalInput = usage.input_tokens ?? 0
        let freshInput = max(0, totalInput - cached)
        let output = (usage.output_tokens ?? 0) + (usage.reasoning_output_tokens ?? 0)
        return UsageEntry(
            timestamp: ts, model: model,
            inputTokens: freshInput, outputTokens: output,
            cacheWriteTokens: 0, cacheReadTokens: cached
        )
    }

    private static func processLine(
        _ line: Data, decoder: JSONDecoder,
        model: inout String,
        lastUsage: inout TokenCountInfo?,
        lastTimestamp: inout Date?
    ) {
        if let meta = try? decoder.decode(SessionMetaLine.self, from: line),
           meta.type == "session_meta",
           let m = meta.payload?.model {
            model = m
        }
        if let event = try? decoder.decode(EventMsgLine.self, from: line),
           event.type == "event_msg",
           event.payload?.type == "token_count",
           let info = event.payload?.info?.total_token_usage {
            lastUsage = info
            lastTimestamp = event.timestamp
        }
    }

    private struct PerFileResult: Sendable {}
    private struct SessionMetaLine: Decodable {
        let type: String?
        let payload: Payload?
        struct Payload: Decodable { let model: String? }
    }
    private struct EventMsgLine: Decodable {
        let type: String?
        let timestamp: Date?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let info: Info?
        }
        struct Info: Decodable { let total_token_usage: TokenCountInfo? }
    }
    private struct TokenCountInfo: Decodable {
        let input_tokens: Int?
        let cached_input_tokens: Int?
        let output_tokens: Int?
        let reasoning_output_tokens: Int?
    }
}
```

> **Note for the executor:** the cache in `JSONLScanner` is line-granular and doesn't fit Codex's "take the last token_count event" semantic cleanly. The simple approach above keeps the streaming + 64 KiB chunking (no full-file String) and drops the cache for the Codex path. If post-landing profiling shows Codex rescanning is a bottleneck, the follow-up is to generalize `JSONLScanner` with a per-file reducer hook — that's out of scope here.

**Step 4: Run tests**

```bash
swift test
```
Expected: all pass.

**Step 5: Commit**

```bash
git add Sources/CliBuddy/Services/Usage/CodexUsageService.swift \
        Tests/CliBuddyTests/CodexUsageServiceTests.swift
git commit -m "refactor(usage): stream Codex rollout files without full-file read

Replaces Data(contentsOf:) + String.split with a 64KiB FileHandle loop,
matching UsageService's streaming shape. Behavior preserved — we still
take the last token_count event per file."
```

---

## Phase 5 — Optional: AppDelegate decomposition

Skip this phase unless Phases 1–4 land cleanly and time remains. `AppDelegate.swift` is 452 lines and does wiring, lifecycle, three bubble coordinators, badge, roaming, approval flow, and socket-bind failure UI. Decomposing is a layering win, not a perf win — the decision to land it is judgment, not obligation.

### Task 5.1: Extract `RootCoordinator`

**Files:**
- Create: `Sources/CliBuddy/Core/RootCoordinator.swift` (new)
- Modify: `Sources/CliBuddy/App/AppDelegate.swift`
- Test: no new tests required — this is a pure extraction; all existing tests must still pass.

**Step 1: Sketch the surface**

`RootCoordinator` owns:
- `store: SessionStore`
- `brain: BuddyBrain`
- `hookServer: HookSocketServer`
- `screens: ScreenManager`
- `roaming: RoamingCoordinator`
- `buddyWindow: BuddyWindow`
- The three bubble windows (`approvalBubble`, `sessionListBubble`, `usageBubble`)
- `presentedApprovals: Set<String>`
- `cancellables`

`AppDelegate` keeps:
- `NSStatusItem` (menu bar + badge)
- `settingsWindow`
- The `@objc` menu actions (`openUsage`, `openSettings`)
- First-launch accessibility prompts (none today, but plausible future home)
- Ownership of a single `RootCoordinator`

**Step 2: Move code in four atomic sub-commits**

Each sub-commit lands with `swift test` passing. The four commits are:

- `refactor(app): introduce RootCoordinator, wire it from AppDelegate` — create the new file, move `store` / `brain` / `hookServer` / `screens` / `roaming` / `buddyWindow` ownership and `applicationDidFinishLaunching` wiring. `AppDelegate` gets a `private let root = RootCoordinator()` and forwards. Menu bar + badge stay on `AppDelegate` for now.
- `refactor(app): move approval bubble into RootCoordinator` — `reconcileApprovalBubble` / `resolveApproval` / `approvalBubble` ivar all move.
- `refactor(app): move session-list bubble into RootCoordinator` — `toggleSessionListBubble` and its window move.
- `refactor(app): move usage bubble + socket-bind alert into RootCoordinator` — `showUsageBubble` + `handleSocketBindFailure` move; `AppDelegate` retains just the `@objc openUsage` action that calls into the root.

Each sub-commit follows:
1. Move the code (Edit-grade patch; no behavior change).
2. `swift test` → green.
3. `swift build` → green.
4. `git commit` with the conventional-commit message above.

**Step 3: Regression check**

After all four sub-commits land, manually smoke-test:

```bash
bash scripts/build.sh
open .build/bundler/apps/CliBuddy/CliBuddy.app
```

Verify:
- Menu bar paw shows, `Usage…` opens bubble with data, `Settings…` opens window, `Quit` quits.
- Click buddy → session-list bubble opens.
- Drag buddy → re-sync position on drop; no jitter.
- Trigger an approval request from a Claude session → bubble pops near buddy; Allow resolves; socket closes.
- Let a session complete → buddy hops once, green flash.
- Quit app → socket unlinks; relaunch — no bind-failure alert.

If any step fails, revert the offending sub-commit before proceeding.

---

## Final verification

After all phases land:

```bash
swift test                              # every suite green
swift build                             # no warnings newly introduced
bash scripts/build.sh                   # .app still produced at known path
```

Open the resulting `.app`, connect a live Claude session, watch a full lifecycle: processing → waitingForApproval → allow → processing → waitingForInput → celebration. No frame drops, no bubble ghosting, no leaked timers in Instruments (if checking).

---

## Reference sub-skills

- Execution: @superpowers:executing-plans
- Verification before calling a phase done: @superpowers:verification-before-completion
- Debugging during implementation: @superpowers:systematic-debugging
- Test rigor: @superpowers:test-driven-development
- Final review before handoff: @superpowers:requesting-code-review
