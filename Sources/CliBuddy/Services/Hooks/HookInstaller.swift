import Foundation

/// Installs / uninstalls the cli-buddy Python hook into Claude Code's
/// `settings.json`. The installer scans existing hook entries by script
/// filename, so it coexists with any other tool that writes its own
/// distinct script. An instance form (`init(claudeDir:)`) exists
/// alongside the static `installIfNeeded()` so tests can inject a tmp dir.
struct HookInstaller {
    static let hookScriptName = "cli-buddy-state.py"

    let claudeDir: URL

    init(claudeDir: URL) {
        self.claudeDir = claudeDir
    }

    /// Static convenience: install into ~/.claude
    static func installIfNeeded() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        try? HookInstaller(claudeDir: dir).install()
    }

    /// Static convenience: check if installed in ~/.claude
    static func isInstalled() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        return HookInstaller(claudeDir: dir).isInstalled()
    }

    /// Static convenience: uninstall from ~/.claude
    static func uninstall() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        try? HookInstaller(claudeDir: dir).uninstall()
    }

    // MARK: - Instance API

    func install() throws {
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(Self.hookScriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")

        try FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.module.url(forResource: "cli-buddy-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try FileManager.default.copyItem(at: bundled, to: pythonScript)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        try updateSettings(at: settings)
    }

    func isInstalled() -> Bool {
        let settings = claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains(Self.hookScriptName) {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    func uninstall() throws {
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(Self.hookScriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains(Self.hookScriptName)
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        let out = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: settings)
    }

    // MARK: - Private

    private func updateSettings(at settingsURL: URL) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = Self.detectPython()
        let command = "\(python) ~/.claude/hooks/\(Self.hookScriptName)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains(Self.hookScriptName)
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        let out = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: settingsURL)
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
