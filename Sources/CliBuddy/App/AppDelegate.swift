import AppKit
import Combine
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.cli-buddy", category: "AppDelegate")

/// Owns the runtime graph: HookSocketServer → SessionStore → BuddyBrain.
/// Also installs the menu-bar icon and the buddy + bubble NSPanels.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var buddyWindow: BuddyWindow!
    private var sessionListBubble: BubbleWindow<SessionListBubbleView>?
    private var sessionListLocalClickMonitor: Any?
    private var sessionListGlobalClickMonitor: Any?
    private var sessionListDismissArmed = false
    private var approvalBubble: BubbleWindow<ApprovalBubbleView>?
    private var usageBubble: BubbleWindow<UsageBubbleView>?
    private var settingsWindow: NSWindow?
    private let usageService = UsageService()
    private let codexUsageService = CodexUsageService()


    /// toolUseIds already surfaced to the user so we don't re-pop the
    /// same bubble on every store update.
    private var presentedApprovals: Set<String> = []

    private var cancellables: Set<AnyCancellable> = []

    private(set) var store: SessionStore!
    private(set) var brain: BuddyBrain!
    private(set) var hookServer: HookSocketServer!
    private let workingFeedback = WorkingFeedbackController()
    // Eager so SwiftUI's Settings scene can bind on first evaluation,
    // which happens before applicationDidFinishLaunching.
    let customization = CustomizationStore()
    private(set) var screens: ScreenManager!
    private(set) var roaming: RoamingCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = SessionStore()
        store.startRecycleTimer()
        brain = BuddyBrain(store: store)
        hookServer = HookSocketServer()
        screens = ScreenManager()
        screens.start()

        // Install hook scripts into ~/.claude and ~/.codex so running
        // Claude / Codex sessions actually route events to us. No-op if
        // already installed (the installer is idempotent).
        HookInstaller.installIfNeeded()
        CodexHookInstaller.installIfNeeded()

        // Warm the usage caches off the main thread so the first ⌘U press
        // doesn't pay the ~5s (Claude) + ~? (Codex) cold-scan cost on a
        // fresh launch.
        usageService.prefetch()
        codexUsageService.prefetch()

        hookServer.start(
            onEvent: { [weak self] event in
                // HookSocketServer fires onEvent from its private dispatch
                // queue. Hop to MainActor before touching the store.
                Task { @MainActor [weak self] in
                    self?.store.apply(event)
                }
            },
            onBindFailure: { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.handleSocketBindFailure(reason: reason)
                }
            }
        )

        // Play 8-bit sounds + drive buddy-level celebration animations
        // on phase transitions.
        store.onPhaseTransition = { [weak self] _, oldPhase, newPhase in
            guard let self else { return }
            if self.customization.value.soundEnabled {
                SoundManager.shared.handlePhaseTransition(from: oldPhase, to: newPhase)
            }
            self.workingFeedback.handlePhaseTransition(from: oldPhase, to: newPhase)
            self.handlePhaseTransitionForBuddyFeedback(from: oldPhase, to: newPhase)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"
        statusItem.button?.toolTip = "cli-buddy"

        let menu = NSMenu()
        let usageItem = NSMenuItem(
            title: "Usage…",
            action: #selector(openUsage),
            keyEquivalent: "u"
        )
        usageItem.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)
        menu.addItem(usageItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit cli-buddy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Place the buddy window on screen. Roaming behavior lands in 6.1.
        let windowSize = Self.buddyWindowSize(for: customization.value)
        buddyWindow = BuddyWindow(size: windowSize)
        buddyWindow.onMouseDown = { [weak self] in
            self?.roaming?.isSuspended = true
        }
        buddyWindow.onMouseUp = { [weak self] wasDrag in
            guard let self else { return }
            if wasDrag {
                self.roaming?.syncPositionWithWindow()
            } else {
                self.workingFeedback.handleBuddyTapWhileWorking()
                self.toggleSessionListBubble()
            }
            self.roaming?.isSuspended = false
        }
        let hostView = NSHostingView(
            rootView: BuddyHostView(
                onHoverChanged: { [weak self] inside in
                    // Freeze roaming while the cursor is on the buddy so
                    // the user can actually click it.
                    if inside {
                        self?.roaming?.pauseAtCurrent()
                    } else {
                        self?.resumeRoamingIfAllowed()
                    }
                }
            )
            .environmentObject(brain)
            .environmentObject(workingFeedback)
            .environmentObject(customization)
        )
        buddyWindow.contentView = hostView
        if let screen = NSScreen.main {
            let origin = CGPoint(
                x: screen.frame.maxX - windowSize.width - 40,
                y: screen.frame.minY + 40
            )
            buddyWindow.place(at: origin)
        }
        buddyWindow.orderFront(nil)

        // Start roaming. Summon the buddy to the cursor-screen center on
        // rising edges into .attention (BuddyBrain fires this when any
        // session enters waitingForApproval / waitingForQuestion).
        roaming = RoamingCoordinator(
            window: buddyWindow,
            screens: screens,
            customization: customization
        )
        brain.onAttentionNeeded = { [weak self] in
            self?.roaming?.summonToCursor()
        }
        applyRoamingPreference()

        // Respect roamingEnabled changes made in settings at runtime.
        customization.$value
            .map(\.roamingEnabled)
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyRoamingPreference() }
            .store(in: &cancellables)

        // Resize the buddy window when pixelSize changes.
        customization.$value
            .map(\.pixelSize)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                let size = Self.buddyWindowSize(for: self.customization.value)
                self.buddyWindow.setContentSize(size)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.orderOutSessionListBubble()
            }
            .store(in: &cancellables)

        // Auto-pop the approval bubble whenever a session enters
        // waitingForApproval. We track presentedApprovals so each
        // toolUseId only pops once.
        // Approval bubble stays on tickRevision because tool_use_id
        // correlation can arrive on a heartbeat that doesn't change
        // the phase. No .dropFirst() — the launch-time no-op reconcile
        // matches the prior $sessions.sink behavior.
        store.$tickRevision
            .sink { [weak self] _ in
                guard let self else { return }
                self.reconcileApprovalBubble(sessions: self.store.sessions)
            }
            .store(in: &cancellables)

        // Badge only reflects phase-level state; fire only on structural
        // changes so we don't re-render on every heartbeat.
        store.$structuralRevision
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMenuBarBadge(sessions: self.store.sessions)
            }
            .store(in: &cancellables)

        logger.info("cli-buddy launched; listening on /tmp/cli-buddy.sock")
    }

    func applicationWillTerminate(_ notification: Notification) {
        roaming?.stop()
        screens?.stop()
        hookServer?.stop()
        store?.stopRecycleTimer()
    }

    @objc func openUsage() {
        showUsageBubble()
    }

    @objc private func openSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(
            rootView: SettingsView().environmentObject(customization)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "cli-buddy Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Roaming gating

    /// Start or stop the roaming timer based on customization.
    private func applyRoamingPreference() {
        guard let roaming else { return }
        if customization.value.roamingEnabled {
            roaming.start()
        } else {
            roaming.stop()
            roaming.pauseAtCurrent()
        }
    }

    /// Resume wandering unless something is keeping us paused (bubble
    /// open, or roaming turned off in settings).
    private func resumeRoamingIfAllowed() {
        guard customization.value.roamingEnabled else { return }
        let hasBubble = (approvalBubble?.isVisible ?? false)
            || (sessionListBubble?.isVisible ?? false)
        guard !hasBubble else { return }
        roaming?.resumeStroll()
    }

    // MARK: - Phase-transition side effects

    /// The buddy's own visual reaction to transitions. Runs regardless
    /// of whether the buddy is in the foreground — the bounce + color
    /// flash draw the user's eye to the desktop cat without a system
    /// banner interrupting them.
    private func handlePhaseTransitionForBuddyFeedback(
        from oldPhase: SessionPhase,
        to newPhase: SessionPhase
    ) {
        // Task just completed → hop + flash green. Widen the guard so
        // that any "active" → waitingForInput counts: tools in progress
        // (running_tool status) also land in .processing, and the user
        // sometimes submits a prompt that goes straight to Stop without
        // hitting a tool at all.
        let wasActive: Bool
        switch oldPhase {
        case .processing, .waitingForApproval, .waitingForQuestion, .compacting:
            wasActive = true
        default:
            wasActive = false
        }
        if wasActive, case .waitingForInput = newPhase {
            logger.info("Phase completion detected → celebrate")
            roaming?.celebrate()
            brain.flash(.waiting, for: 1.2)
        }
    }

    /// Paw print menu bar title + a badge count of sessions currently
    /// waiting on the user (approvals or complete-but-no-input).
    private func updateMenuBarBadge(sessions: [String: SessionState]) {
        let pending = sessions.values.filter { state in
            switch state.phase {
            case .waitingForApproval, .waitingForQuestion, .waitingForInput:
                return true
            default:
                return false
            }
        }.count

        if pending > 0 {
            statusItem.button?.title = "🐾 \(pending)"
        } else {
            statusItem.button?.title = "🐾"
        }
    }

    private static func buddyWindowSize(for c: BuddyCustomization) -> CGSize {
        let p = CGFloat(c.pixelSize)
        return CGSize(
            width:  CGFloat(BuddySprite.gridW) * p,
            height: CGFloat(BuddySprite.gridH) * p
                + BuddyHostView.topOverlayPadding(for: p)
        )
    }

    // MARK: - Socket failure

    private func handleSocketBindFailure(reason: String) {
        logger.error("Socket bind failed: \(reason, privacy: .public)")
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: "🐾",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        let alert = NSAlert()
        alert.messageText = "cli-buddy couldn't bind its socket"
        alert.informativeText = """
            \(reason)

            This usually means another cli-buddy instance is already running, or a previous crash left /tmp/cli-buddy.sock behind. Quit any running instance and relaunch.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Approval bubble

    private func reconcileApprovalBubble(sessions: [String: SessionState]) {
        // Find the first (oldest-arriving) waitingForApproval context that
        // we haven't presented yet.
        let pending = sessions.values.compactMap { state -> PermissionContext? in
            guard case .waitingForApproval(let ctx) = state.phase else { return nil }
            guard !presentedApprovals.contains(ctx.toolUseId) else { return nil }
            return ctx
        }
        guard let ctx = pending.first else { return }

        presentedApprovals.insert(ctx.toolUseId)

        // Pause roaming so the bubble stays pinned next to the buddy.
        roaming?.pauseAtCurrent()

        let view = ApprovalBubbleView(
            context: ctx,
            onDecision: { [weak self] allow in
                self?.resolveApproval(toolUseId: ctx.toolUseId, allow: allow)
            },
            onClose: { [weak self] in
                self?.approvalBubble?.orderOut(nil)
                self?.roaming?.resumeStroll()
            }
        )

        if let existing = approvalBubble {
            existing.swap(rootView: view)
            existing.present(nextTo: buddyWindow.frame)
        } else {
            let bubble = BubbleWindow(
                size: CGSize(width: 420, height: 340),
                rootView: view
            )
            approvalBubble = bubble
            bubble.present(nextTo: buddyWindow.frame)
        }
    }

    private func resolveApproval(toolUseId: String, allow: Bool) {
        hookServer.respondToPermission(
            toolUseId: toolUseId,
            decision: allow ? "allow" : "deny",
            reason: allow ? nil : "Denied via cli-buddy"
        )
        approvalBubble?.orderOut(nil)
        // Resume wandering.
        roaming?.resumeStroll()
    }

    // MARK: - Usage bubble

    private func showUsageBubble() {
        if let existing = usageBubble, existing.isVisible {
            existing.orderOut(nil)
            return
        }

        let placeholder = UsageBubbleView(
            data: nil,
            onRefresh: { [weak self] in self?.showUsageBubble() },
            onClose: { [weak self] in self?.usageBubble?.orderOut(nil) }
        )

        if let existing = usageBubble {
            existing.swap(rootView: placeholder)
            existing.present(below: statusItem)
        } else {
            let bubble = BubbleWindow(
                size: CGSize(width: 380, height: 480),
                rootView: placeholder
            )
            usageBubble = bubble
            bubble.present(below: statusItem)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Kick off both scans in parallel, but render Claude as soon
            // as it lands so the user gets feedback at the ~5s mark
            // instead of waiting on the ~150s Codex cold scan.
            async let claudePair = self.usageService.computeAll(dailyDays: 14)
            async let codex = self.codexUsageService.computeBreakdown()

            let (claude, daily) = await claudePair
            Self.logDaily(daily)
            let onRefresh: () -> Void = { [weak self] in self?.showUsageBubble() }
            let onClose: () -> Void = { [weak self] in self?.usageBubble?.orderOut(nil) }
            self.usageBubble?.swap(rootView: UsageBubbleView(
                data: .init(claude: claude, codex: nil),
                onRefresh: onRefresh, onClose: onClose
            ))

            let codexBreakdown = await codex
            self.usageBubble?.swap(rootView: UsageBubbleView(
                data: .init(claude: claude, codex: codexBreakdown),
                onRefresh: onRefresh, onClose: onClose
            ))
        }
    }

    /// Dumps the deduped per-day claude usage to os_log. Tail with
    /// `log stream --predicate 'subsystem == "com.cli-buddy"' --level info`.
    private static func logDaily(_ rows: [UsageService.DailyRow]) {
        guard !rows.isEmpty else {
            logger.info("usage daily: no entries in window")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var lines = ["usage daily (deduped, last \(rows.count)d, newest first):"]
        var total = 0.0
        for row in rows {
            let s = row.summary
            let cacheTotal = s.cacheReadTokens + s.cacheWriteTokens
            lines.append(String(
                format: "  %@  $%7.2f  msgs=%4d  in=%@  out=%@  cache=%@",
                df.string(from: row.day), s.cost, s.messageCount,
                fmt(s.inputTokens), fmt(s.outputTokens), fmt(cacheTotal)
            ))
            total += s.cost
        }
        lines.append(String(format: "  ── total $%.2f over %d days", total, rows.count))
        logger.info("\(lines.joined(separator: "\n"), privacy: .public)")
    }

    /// Compact integer formatter (12_345 → "12.3K", 1_234_567 → "1.2M").
    private static func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }

    // MARK: - Session list bubble

    private func toggleSessionListBubble() {
        if let existing = sessionListBubble, existing.isVisible {
            orderOutSessionListBubble()
            return
        }

        let view = SessionListBubbleView(
            store: store,
            onJump: { [weak self] session in
                TerminalRouter.jump(to: session)
                self?.orderOutSessionListBubble()
            },
            onClose: { [weak self] in
                self?.orderOutSessionListBubble()
            }
        )

        if let existing = sessionListBubble {
            existing.swap(rootView: view)
            existing.present(nextTo: buddyWindow.frame)
            armSessionListDismiss()
            return
        }

        let bubble = BubbleWindow(
            size: CGSize(width: 380, height: 320),
            rootView: view
        )
        sessionListBubble = bubble
        bubble.present(nextTo: buddyWindow.frame)
        armSessionListDismiss()
    }

    private func armSessionListDismiss() {
        sessionListDismissArmed = false
        removeSessionListDismissMonitors()

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let bubble = self.sessionListBubble,
                  bubble.isVisible else { return }

            self.sessionListDismissArmed = true
            self.sessionListLocalClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                self?.dismissSessionListIfNeeded()
                return event
            }
            self.sessionListGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.dismissSessionListIfNeeded()
            }
        }
    }

    private func dismissSessionListIfNeeded() {
        guard sessionListDismissArmed,
              let bubble = sessionListBubble,
              bubble.isVisible else { return }

        let location = NSEvent.mouseLocation
        if bubble.frame.contains(location) { return }
        orderOutSessionListBubble()
    }

    private func orderOutSessionListBubble() {
        sessionListDismissArmed = false
        removeSessionListDismissMonitors()
        sessionListBubble?.orderOut(nil)
    }

    private func removeSessionListDismissMonitors() {
        if let sessionListLocalClickMonitor {
            NSEvent.removeMonitor(sessionListLocalClickMonitor)
            self.sessionListLocalClickMonitor = nil
        }
        if let sessionListGlobalClickMonitor {
            NSEvent.removeMonitor(sessionListGlobalClickMonitor)
            self.sessionListGlobalClickMonitor = nil
        }
    }
}
