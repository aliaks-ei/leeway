import Foundation
@testable import LeewayCore
import Testing

struct AccountArrangementTests {
    private func account(_ provider: Provider, _ path: String, identity: String? = nil, lastUsed: Double = 0) -> AccountConfig {
        AccountConfig(provider: provider, path: path, identity: identity, lastUsed: Date(timeIntervalSince1970: lastUsed))
    }

    @Test func namesFoldersAfterTheirSuffix() {
        #expect(AccountArrangement.autoName(account(.claude, "/h/.claude-work")) == "Work")
        #expect(AccountArrangement.autoName(account(.codex, "/h/.codex_side_project")) == "Side Project")
        var main = account(.claude, "/h/.claude")
        #expect(AccountArrangement.autoName(main) == "Default")
        main.email = "me@x.y"
        #expect(AccountArrangement.autoName(main) == "me@x.y")
    }

    @Test func appliesSavedOrderThenScanOrder() {
        let a = account(.claude, "/a"), b = account(.claude, "/b"), c = account(.claude, "/c")
        let ordered = AccountArrangement.applyOrder([a, b, c], saved: [c.id, a.id, c.id])
        #expect(ordered.map(\.path) == ["/c", "/a", "/b"])
    }

    @Test func appliesOverrides() {
        let a = account(.claude, "/h/.claude-work")
        let result = AccountArrangement.arrange([a], overrides: [a.id: AccountOverride(name: "Job", hidden: true)],
                                                order: [], cached: [:])
        #expect(result[0].name == "Job")
        #expect(result[0].isHidden)
        #expect(!result[0].isVisible)
    }

    @Test func keepsTheDuplicateThatWorked() {
        let old = account(.claude, "/old", identity: "same", lastUsed: 200)
        let new = account(.claude, "/new", identity: "same", lastUsed: 100)
        let untried = AccountArrangement.resolveDuplicates([old, new], worked: [:])
        #expect(untried[0].duplicateOf == nil)
        #expect(untried[1].duplicateOf != nil)

        let worked = AccountArrangement.resolveDuplicates([old, new], worked: [old.id: false, new.id: true])
        #expect(worked[0].duplicateOf != nil)
        #expect(worked[1].duplicateOf == nil)
    }

    @Test func takesCodexIdentityFromTheLastReading() {
        let a = account(.codex, "/a"), b = account(.codex, "/b")
        let usage = AccountUsage(measuredAt: .now, email: "e", identity: "codex::e")
        let result = AccountArrangement.arrange([a, b], overrides: [:], order: [], cached: [a.id: usage, b.id: usage])
        #expect(result.filter(\.isVisible).count == 1)
        #expect(result[0].email == "e")
    }
}

struct AccountRepositoryTests {
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let manager = FileManager.default
        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: home + "/" + path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".claude.json", #"{"oauthAccount": {"emailAddress": "main@x", "accountUuid": "u"}}"#)
        try manager.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try write(".claude-work/.claude.json", #"{"oauthAccount": {"emailAddress": "work@x", "accountUuid": "w"}}"#)
        try write(".claude-loggedout/.claude.json", #"{"projects": {}}"#)
        try write(".codex/auth.json", "{}")
        try write(".codex-empty/config.toml", "")
        return home
    }

    @Test func findsSignedInFolders() async throws {
        let home = try makeHome()
        let repository = AccountRepository(home: home, configs: ClaudeConfigStore(home: home))
        let found = await repository.scan(customFolders: [])
        #expect(found.map(\.path) == [home + "/.claude", home + "/.claude-work", home + "/.codex"])
        #expect(found.map(\.isDefaultFolder) == [true, false, true])
        #expect(found[0].email == "main@x")
        #expect(found[1].identity == "claude:w:")
    }

    @Test func addsCustomFoldersEvenWithoutLogin() async throws {
        let home = try makeHome()
        let repository = AccountRepository(home: home, configs: ClaudeConfigStore(home: home))
        let found = await repository.scan(customFolders: [CustomFolder(provider: .codex, home: home + "/.codex-empty")])
        let custom = try #require(found.last)
        #expect(custom.isCustom)
        #expect(custom.path == home + "/.codex-empty")
    }

    @Test func detectsProviderOfAFolder() throws {
        let home = try makeHome()
        #expect(AccountRepository.detectProvider(folder: URL(fileURLWithPath: home + "/.codex-empty")) == .codex)
        #expect(AccountRepository.detectProvider(folder: URL(fileURLWithPath: home + "/.claude-work")) == .claude)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("leeway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(AccountRepository.detectProvider(folder: empty) == nil)
    }
}

struct AccountConfigTests {
    @Test func quotesLoginCommand() {
        let home = NSHomeDirectory()
        let plain = AccountConfig(provider: .claude, path: home + "/.claude-work")
        #expect(plain.loginCommand == "CLAUDE_CONFIG_DIR=~/.claude-work claude")
        let spaced = AccountConfig(provider: .codex, path: "/Volumes/My Disk/codex")
        #expect(spaced.loginCommand == "CODEX_HOME='/Volumes/My Disk/codex' codex login")
        let main = AccountConfig(provider: .claude, path: home + "/.claude", isDefaultFolder: true)
        #expect(main.loginCommand == "claude")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
    }

    @Test func picksMenuBarWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let usage = AccountUsage(session: UsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(-1)),
                                 weekly: UsageWindow(usedPercent: 70), measuredAt: now)
        // The session window has reset, so it counts as 0.
        #expect(usage.menuBarUsed(.sessionFirst, now: now) == 0)
        #expect(usage.menuBarUsed(.weeklyFirst, now: now) == 70)
        #expect(usage.menuBarUsed(.closest, now: now) == 70)
    }
}
