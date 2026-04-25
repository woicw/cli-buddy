import AppKit
import Foundation

/// Ghostty lookup via AppleScript: iterate terminals and focus the one
/// whose working directory matches. Falls back to plain activation if
/// no match is found or AppleScript fails.
enum GhosttyJumper {
    static func activate(cwd: String) {
        let escaped = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // 'working directory contains' handles trailing-slash / prefix
        // mismatches that an exact equality check would miss.
        let script = """
        tell application "System Events"
            if not (exists process "Ghostty") then
                tell application "Ghostty" to activate
                return
            end if
        end tell
        tell application "Ghostty"
            try
                set matches to every terminal whose working directory contains "\(escaped)"
                if (count of matches) > 0 then
                    focus (item 1 of matches)
                    activate
                    return
                end if
            end try
            activate
        end tell
        """
        runOsascript(script)
    }

    private static func runOsascript(_ script: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}
