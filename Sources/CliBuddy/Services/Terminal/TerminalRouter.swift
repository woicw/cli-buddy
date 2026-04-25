import AppKit
import Foundation

/// Routes a terminal-jump request to the right per-app implementation
/// based on `SessionState.terminalApp`. iTerm2 gets precise session
/// lookup via AppleScript; other apps simply come to the front.
enum TerminalRouter {
    static func jump(to session: SessionState) {
        switch session.terminalApp {
        case "iTerm2":
            ITerm2Jumper.activate(cwd: session.cwd)
        case "Terminal":
            TerminalJumper.activateTerminalApp()
        case "Ghostty":
            GhosttyJumper.activate(cwd: session.cwd)
        case "Warp":
            TerminalJumper.activateWarp()
        case "VS Code":
            TerminalJumper.activateVSCode()
        case "Cursor":
            TerminalJumper.activateCursor()
        case "Codex":
            CodexJumper.activate(sessionId: session.sessionId)
        default:
            // Unknown terminal: try Terminal.app as a last resort so the
            // user at least sees *some* terminal come forward.
            TerminalJumper.activateTerminalApp()
        }
    }
}
