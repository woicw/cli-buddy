import Testing
import Foundation
@testable import CliBuddy

@Suite struct CodexHookInstallerTests {
    @Test func installHooksJSONAddsManagedEntry() throws {
        let mutation = try CodexHookInstaller.installHooksJSON(
            existingData: nil,
            hookCommand: "/tmp/cli-buddy-state.py"
        )
        #expect(mutation.contents != nil)
        #expect(mutation.changed)
        let json = try JSONSerialization.jsonObject(with: mutation.contents!) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil)
    }

    @Test func installTwiceIsIdempotent() throws {
        let first = try CodexHookInstaller.installHooksJSON(
            existingData: nil,
            hookCommand: "/tmp/cli-buddy-state.py"
        ).contents!
        let second = try CodexHookInstaller.installHooksJSON(
            existingData: first,
            hookCommand: "/tmp/cli-buddy-state.py"
        ).contents!
        // Re-install replaces our managed group in place; count of SessionStart groups stays 1
        let json = try JSONSerialization.jsonObject(with: second) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let managed = sessionStart.filter { group in
            guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
            return hooks.contains { ($0["command"] as? String ?? "").contains("cli-buddy-state.py") }
        }
        #expect(managed.count == 1)
    }

    @Test func enableCodexHooksFeatureAddsFlagToEmptyConfig() {
        let result = CodexHookInstaller.enableCodexHooksFeature(in: "")
        #expect(result.changed)
        #expect(result.featureEnabledByInstaller)
        #expect(result.contents.contains("[features]"))
        #expect(result.contents.contains("codex_hooks = true"))
    }

    @Test func enableCodexHooksFeatureIsIdempotent() {
        let initial = CodexHookInstaller.enableCodexHooksFeature(in: "").contents
        let again = CodexHookInstaller.enableCodexHooksFeature(in: initial)
        #expect(!again.changed)
    }
}
