import AppKit
import Foundation

/// Activates terminal apps that don't have (or we don't implement) a
/// precise cwd-based session lookup. Just brings the app to the front.
enum TerminalJumper {
    static func activate(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    static func activateTerminalApp() { activate(bundleIdentifier: "com.apple.Terminal") }
    static func activateGhostty()     { activate(bundleIdentifier: "com.mitchellh.ghostty") }
    static func activateWarp()        { activate(bundleIdentifier: "dev.warp.Warp-Stable") }
    static func activateVSCode()      { activate(bundleIdentifier: "com.microsoft.VSCode") }
    static func activateCursor()      { activate(bundleIdentifier: "com.todesktop.230313mzl4w4u92") }
    static func activateCodex()       { activate(bundleIdentifier: "com.openai.codex") }
}
