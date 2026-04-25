import AppKit
import Foundation

/// Activates iTerm2 and tries to focus the session whose working
/// directory matches `cwd`. Falls back to simply activating iTerm2 if
/// no session matches (e.g. the user closed that tab).
enum ITerm2Jumper {
    /// Whether iTerm2 is installed. If not, the caller can fall back to
    /// TerminalRouter's default activation path.
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    static func activate(cwd: String) {
        // The AppleScript searches every window → tab → session and
        // selects the first one whose session.path variable matches cwd.
        // If none match we still leave iTerm2 as the frontmost app.
        let escaped = cwd.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if (variable of s named "session.path") is "\(escaped)" then
                                select s
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        """
        runOsascript(script)
    }

    // MARK: - Private

    private static func runOsascript(_ script: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Non-blocking: we don't wait. iTerm2's AppleScript dispatch
            // is fast, but we never want to stall the main actor on a
            // misbehaving terminal.
        } catch {
            // Silent — terminal jump is best-effort.
        }
    }
}
