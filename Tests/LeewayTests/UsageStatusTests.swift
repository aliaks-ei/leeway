import Foundation
import LeewayCore
import Testing
@testable import Leeway

@MainActor
struct UsageStatusTests {
    @Test func failedRefreshKeepsReadingAndRetryRestoresCurrentState() async throws {
        let now = Date.now
        let fixture = Fixture(cached: AccountUsage(session: UsageWindow(usedPercent: 87), measuredAt: now.addingTimeInterval(-1800)),
                              outcomes: [.failure(.codexTimedOut), .success(AccountUsage(session: UsageWindow(usedPercent: 24), measuredAt: now))])
        defer { fixture.cleanUp() }
        await fixture.store.refreshAll()
        #expect(fixture.store.refreshSummary(now: now).contains("Refresh failed"))
        #expect(fixture.store.refreshSummary(now: now).contains("30m ago"))
        let stale = try #require(fixture.store.menuBarItems(now: now).first)
        #expect(stale.used == 87)
        #expect(stale.isStale)
        #expect(stale.accountName == fixture.store.accounts.first?.name)
        #expect(stale.windowName == "5-hour")

        await fixture.store.retry(fixture.account)
        let current = try #require(fixture.store.menuBarItems(now: now).first)
        #expect(current.used == 24)
        #expect(!current.isStale)
        #expect(fixture.store.refreshSummary(now: now) == "Updated just now")
        #expect(await fixture.provider.calls == 2)
    }

    @Test func passedResetNeverShowsZeroOrFullAvailability() async throws {
        let now = Date.now
        let fixture = Fixture(cached: AccountUsage(session: UsageWindow(usedPercent: 95, resetsAt: now.addingTimeInterval(-60)), measuredAt: now.addingTimeInterval(-600)),
                              outcomes: [.failure(.codexTimedOut)])
        defer { fixture.cleanUp() }
        await fixture.store.refreshAll()
        let item = try #require(fixture.store.menuBarItems(now: now).first)
        #expect(item.used == nil)
        #expect(item.awaitingReset)
        #expect(item.isStale)
        #expect(fixture.store.state(fixture.account).usage?.session?.usedPercent == 95)
    }

    @Test func successfulFetchOfOldReadingDoesNotClaimJustUpdated() async {
        let now = Date.now
        let old = AccountUsage(session: UsageWindow(usedPercent: 42), measuredAt: now.addingTimeInterval(-1800))
        let fixture = Fixture(cached: old, outcomes: [.success(old)])
        defer { fixture.cleanUp() }
        await fixture.store.refreshAll()
        #expect(fixture.store.refreshSummary(now: now).hasPrefix("Readings not current"))
        #expect(fixture.store.menuBarItems(now: now).first?.isStale == true)
    }

    @Test func recoveryCommandsKeepTheCorrectAccountFolder() {
        let account = AccountConfig(provider: .claude, path: "/Volumes/My Disk/claude-work")
        #expect(UsageError.signInExpired.recoveryCommand(for: account) == "CLAUDE_CONFIG_DIR='/Volumes/My Disk/claude-work' claude")
        #expect(UsageError.notSignedIn(.claude, loginCommand: "custom-claude").recoveryCommand(for: account) == "custom-claude")
        #expect(UsageError.renewalFailed(loginCommand: "custom-renew").recoveryCommand(for: account) == "custom-renew")
        #expect(UsageError.codexNotFound.recoveryCommand(for: account) == nil)
        #expect(UsageError.codexTimedOut.recoveryCommand(for: account) == nil)
    }

    @MainActor
    private struct Fixture {
        let suite = "LeewayTests.\(UUID().uuidString)"
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("leeway-test-\(UUID().uuidString).json")
        let account: AccountConfig
        let provider: ScriptedProvider
        let store: UsageStore

        init(cached: AccountUsage, outcomes: [Result<AccountUsage, UsageError>]) {
            account = AccountConfig(provider: .codex, path: "/tmp/leeway-test-codex", isDefaultFolder: true)
            provider = ScriptedProvider(outcomes: outcomes)
            let cache = UsageCache(file: cacheURL)
            cache.save([account.id: cached])
            let accounts = [account]
            store = UsageStore(settings: AppSettings(defaults: UserDefaults(suiteName: suite)!), scan: { _ in accounts },
                               providers: [.codex: provider], configs: ClaudeConfigStore(), cache: cache)
        }

        func cleanUp() {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    private actor ScriptedProvider: UsageProvider {
        var outcomes: [Result<AccountUsage, UsageError>]
        private(set) var calls = 0

        init(outcomes: [Result<AccountUsage, UsageError>]) { self.outcomes = outcomes }

        func fetch(_ account: AccountConfig, cached: AccountUsage?, context: FetchContext) async throws -> AccountUsage {
            calls += 1
            return try outcomes.removeFirst().get()
        }
    }
}
