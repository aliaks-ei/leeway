import Foundation
@testable import LeewayCore
import Testing

/// A Keychain that holds an expired token until the fake CLI renews it.
private actor FakeKeychain: ClaudeCredentialSource {
    var token = ClaudeCredentials(accessToken: "old", expiresAt: .distantPast)
    var reads = 0

    func credentials(configDir: String) async throws -> ClaudeCredentials? {
        reads += 1
        return token
    }

    func renew() { token = ClaudeCredentials(accessToken: "new", expiresAt: .distantFuture) }
}

private actor FakeRenewer: ClaudeSignInRenewer {
    let keychain: FakeKeychain
    let succeeds: Bool
    var calls = 0

    init(keychain: FakeKeychain, succeeds: Bool = true) {
        self.keychain = keychain
        self.succeeds = succeeds
    }

    func renew(_ account: AccountConfig) async {
        calls += 1
        // Like the real CLI, take a while, so a second fetch arrives during the renewal.
        try? await Task.sleep(for: .milliseconds(200))
        if succeeds { await keychain.renew() }
    }
}

private actor FakeClient: ClaudeUsageClient {
    var result: Result<AccountUsage, any Error>
    var calls: [String] = []

    init(_ result: Result<AccountUsage, any Error>) { self.result = result }

    func usage(token: String) async throws -> AccountUsage {
        calls.append(token)
        return try result.get()
    }
}

struct ClaudeUsageProviderTests {
    private let account = AccountConfig(provider: .claude, path: "/tmp/leeway-tests/.claude-work")
    private let reading = AccountUsage(session: UsageWindow(usedPercent: 10), measuredAt: .now)

    private func provider(keychain: FakeKeychain, renewer: FakeRenewer, client: FakeClient,
                          snapshot: AccountUsage? = nil) -> ClaudeUsageProvider {
        ClaudeUsageProvider(credentials: keychain, client: client, renewer: renewer,
                            configs: ClaudeConfigStore(home: "/tmp/leeway-tests"), readSnapshot: { _ in snapshot })
    }

    /// Two fetches for one account at the same time must start one CLI, not two.
    @Test func renewsOnceForConcurrentFetches() async throws {
        let keychain = FakeKeychain()
        let renewer = FakeRenewer(keychain: keychain)
        let client = FakeClient(.success(reading))
        let provider = provider(keychain: keychain, renewer: renewer, client: client)
        let context = FetchContext(renewClaudeSignIns: true)

        async let first = provider.fetch(account, cached: nil, context: context)
        async let second = provider.fetch(account, cached: nil, context: context)
        _ = try await (first, second)

        #expect(await renewer.calls == 1)
        #expect(await client.calls.first == "new")
    }

    @Test func reportsExpiredSignInWhenRenewalIsOff() async {
        let keychain = FakeKeychain()
        let renewer = FakeRenewer(keychain: keychain)
        let provider = provider(keychain: keychain, renewer: renewer, client: FakeClient(.success(reading)))
        await #expect(throws: UsageError.signInExpired) {
            try await provider.fetch(account, cached: nil, context: FetchContext(renewClaudeSignIns: false))
        }
        #expect(await renewer.calls == 0)
    }

    @Test func waitsBeforeRetryingAFailedRenewal() async {
        let keychain = FakeKeychain()
        let renewer = FakeRenewer(keychain: keychain, succeeds: false)
        let provider = provider(keychain: keychain, renewer: renewer, client: FakeClient(.success(reading)))
        let context = FetchContext(renewClaudeSignIns: true)
        for _ in 0 ..< 2 {
            await #expect(throws: UsageError.renewalFailed(loginCommand: account.loginCommand)) {
                try await provider.fetch(account, cached: nil, context: context)
            }
        }
        #expect(await renewer.calls == 1)
    }

    @Test func backsOffAfterRateLimit() async throws {
        let keychain = FakeKeychain()
        await keychain.renew()
        let client = FakeClient(.failure(ClaudeAPIError.rateLimited(retryAfter: 600)))
        let provider = provider(keychain: keychain, renewer: FakeRenewer(keychain: keychain), client: client)
        let context = FetchContext()

        let first = try await provider.fetch(account, cached: reading, context: context)
        #expect(first.session == reading.session)
        await #expect(throws: UsageError.rateLimited) {
            try await provider.fetch(account, cached: nil, context: context)
        }
        #expect(await client.calls.count == 1)
    }

    @Test func prefersNewerSnapshot() async throws {
        let keychain = FakeKeychain()
        await keychain.renew()
        let old = AccountUsage(session: UsageWindow(usedPercent: 10), measuredAt: Date(timeIntervalSince1970: 0),
                               scoped: [ScopedWindow(name: "Fable", window: UsageWindow(usedPercent: 5))])
        let snapshot = AccountUsage(session: UsageWindow(usedPercent: 50), measuredAt: .distantFuture)
        let provider = provider(keychain: keychain, renewer: FakeRenewer(keychain: keychain),
                                client: FakeClient(.success(old)), snapshot: snapshot)
        let usage = try await provider.fetch(account, cached: nil, context: FetchContext())
        #expect(usage.session?.usedPercent == 50)
        // The statusline has no per-model windows, so the API's stay.
        #expect(usage.scoped?.first?.name == "Fable")
    }
}

struct ClaudeRenewalTests {
    @Test func turnsOffUpdaterAndForeignSettings() {
        let base = ["PATH": "/bin", "CLAUDE_CONFIG_DIR": "/other", "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_X": "1"]
        let custom = ClaudeCLIRenewer.environment(for: AccountConfig(provider: .claude, path: "/h/.claude-work"), base: base)
        #expect(custom["CLAUDE_CONFIG_DIR"] == "/h/.claude-work")
        #expect(custom["ANTHROPIC_API_KEY"] == nil)
        #expect(custom["CLAUDE_CODE_X"] == nil)
        #expect(custom["DISABLE_AUTOUPDATER"] == "1")
        #expect(custom["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(custom["PATH"] == "/bin")

        let main = ClaudeCLIRenewer.environment(for: AccountConfig(provider: .claude, path: "/h/.claude", isDefaultFolder: true), base: base)
        #expect(main["CLAUDE_CONFIG_DIR"] == nil)
    }
}
