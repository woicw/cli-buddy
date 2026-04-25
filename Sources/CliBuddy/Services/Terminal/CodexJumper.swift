import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cli-buddy", category: "CodexJumper")

/// Deep-links into a Codex Desktop thread via the `codex://threads/<id>`
/// URL scheme discovered inside Codex.app. Falls back to plain app
/// activation when we don't have a session id.
///
/// Codex's Electron `open-url` listener attaches after `app-ready`, so
/// cold-launches via `NSWorkspace.open(url)` silently drop the deep
/// link. When Codex isn't already running, launch it first, give the
/// listener a moment to wire up, then dispatch the URL.
enum CodexJumper {
    private static let bundleIdentifier = "com.openai.codex"
    private static let coldStartDelay: TimeInterval = 2.0

    static func activate(sessionId: String) {
        guard !sessionId.isEmpty,
              let url = URL(string: "codex://threads/\(sessionId)") else {
            logger.info("Codex jump: no sessionId, activating app only")
            TerminalJumper.activateCodex()
            return
        }

        if isCodexRunning() {
            logger.info("Codex running → dispatching \(url.absoluteString, privacy: .public)")
            activateRunningCodex()
            dispatch(url: url)
        } else {
            logger.info("Codex cold → launching before URL dispatch")
            launchCodexThenOpen(url: url)
        }
    }

    private static func isCodexRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private static func activateRunningCodex() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            _ = app.activate(options: [])
        }
    }

    private static func codexAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private static func dispatch(url: URL) {
        guard let appURL = codexAppURL() else {
            logger.warning("Codex.app not found for \(bundleIdentifier, privacy: .public)")
            NSWorkspace.shared.open(url)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                logger.error("Codex URL dispatch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func launchCodexThenOpen(url: URL) {
        guard let appURL = codexAppURL() else {
            logger.warning("Codex.app not found for \(bundleIdentifier, privacy: .public)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                logger.error("Codex launch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + coldStartDelay) {
                logger.info("Codex warm → dispatching \(url.absoluteString, privacy: .public)")
                activateRunningCodex()
                dispatch(url: url)
            }
        }
    }
}
