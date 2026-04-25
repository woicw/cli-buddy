import Testing
import Foundation
@testable import CliBuddy

@Suite struct HookInstallerTests {
    private func makeTmpDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-buddy-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func installIsIdempotent() throws {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inst = HookInstaller(claudeDir: dir)
        try inst.install()
        try inst.install()

        let settings = dir.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: settings)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        // PreToolUse should have exactly one entry after two installs (dedup by script name)
        let preToolUse = hooks["PreToolUse"] as! [[String: Any]]
        let ourEntries = preToolUse.filter { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { ($0["command"] as? String ?? "").contains("cli-buddy-state.py") }
        }
        #expect(ourEntries.count == 1)
    }

    @Test func installAndThenIsInstalledReturnsTrue() throws {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inst = HookInstaller(claudeDir: dir)
        try inst.install()
        #expect(inst.isInstalled())
    }

    @Test func uninstallRemovesEntries() throws {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inst = HookInstaller(claudeDir: dir)
        try inst.install()
        try inst.uninstall()
        #expect(!inst.isInstalled())
    }
}
