import Foundation

/// Reads Claude quota for one `CLAUDE_CONFIG_DIR`.
///
/// Two sources, newest wins:
/// 1. The snapshot that `scripts/claude-statusline-snapshot.sh` writes from the statusline's `rate_limits`.
/// 2. `GET /api/oauth/usage` with the access token Claude Code keeps in the Keychain for that dir.
///
/// The token is never refreshed here: refresh tokens rotate, so a refresh from this app could sign the CLI
/// out. When the token has expired, `ClaudeSignInRenewer` lets the CLI renew it, at most once at a time
/// for each account.
public actor ClaudeUsageProvider: UsageProvider {
    public typealias SnapshotReader = @Sendable (String) -> AccountUsage?

    private let credentials: any ClaudeCredentialSource
    private let client: any ClaudeUsageClient
    private let renewer: any ClaudeSignInRenewer
    private let configs: ClaudeConfigStore
    private let readSnapshot: SnapshotReader

    private var apiBlockedUntil: [String: Date] = [:]
    private var lastAPIRead: [String: Date] = [:]
    private var renewalFailedAt: [String: Date] = [:]
    /// Renewals in progress. A second fetch for the same account waits for the first renewal instead of
    /// starting another CLI: two CLIs that refresh the same rotating token can sign each other out.
    private var renewals: [String: Task<ClaudeCredentials?, Never>] = [:]

    static let minAPIInterval: TimeInterval = 120
    static let renewalRetryInterval: TimeInterval = 15 * 60
    static let defaultBackOff: TimeInterval = 15 * 60

    public init(credentials: any ClaudeCredentialSource, client: any ClaudeUsageClient, renewer: any ClaudeSignInRenewer,
                configs: ClaudeConfigStore, readSnapshot: @escaping SnapshotReader = { ClaudeSnapshot.read(configDir: $0) }) {
        self.credentials = credentials
        self.client = client
        self.renewer = renewer
        self.configs = configs
        self.readSnapshot = readSnapshot
    }

    /// The provider with the real Keychain, endpoint and CLI.
    public static func live(configs: ClaudeConfigStore, locator: CLILocator = .shared) -> ClaudeUsageProvider {
        let keychain = KeychainCredentialSource()
        return ClaudeUsageProvider(
            credentials: keychain,
            client: ClaudeHTTPUsageClient(),
            renewer: ClaudeCLIRenewer(credentials: keychain, locator: locator),
            configs: configs)
    }

    public func fetch(_ account: AccountConfig, cached: AccountUsage?, context: FetchContext) async throws -> AccountUsage {
        let dir = account.path
        // The statusline has no per-model windows, so a snapshot keeps the last API reading of them.
        let snapshot = readSnapshot(dir).map { $0.with(scoped: cached?.scoped) }
        var plan = await configs.config(configDir: dir)?.planName

        let found: ClaudeCredentials?
        do {
            found = try await credentials.credentials(configDir: dir)
        } catch {
            if let snapshot { return snapshot.with(plan: plan) }
            throw UsageError(error)
        }
        guard var credentials = found else {
            if let snapshot { return snapshot.with(plan: plan) }
            throw await notSignedIn(account)
        }
        if credentials.isExpired() {
            guard let fresh = await renewed(account, context: context) else {
                if let snapshot { return snapshot.with(plan: plan) }
                throw context.renewClaudeSignIns
                    ? UsageError.renewalFailed(loginCommand: account.loginCommand)
                    // Usage cannot grow in Claude Code until the CLI runs again and renews the token.
                    : UsageError.signInExpired
            }
            credentials = fresh
        }
        plan = credentials.planName ?? plan

        // The endpoint rate-limits hard, so call it at most every two minutes and back off after a 429.
        let now = Date.now
        let blocked = apiBlockedUntil[account.id].map { $0 > now } ?? false
        let tooSoon = lastAPIRead[account.id].map { now.timeIntervalSince($0) < Self.minAPIInterval } ?? false
        if blocked || tooSoon, let usage = AccountUsage.newest(snapshot, cached) {
            return usage.with(plan: plan)
        }
        if blocked { throw UsageError.rateLimited }

        do {
            lastAPIRead[account.id] = now
            var usage = try await client.usage(token: credentials.accessToken)
            usage.plan = plan
            return (AccountUsage.newest(usage, snapshot) ?? usage).with(scoped: usage.scoped)
        } catch let ClaudeAPIError.rateLimited(retryAfter) {
            apiBlockedUntil[account.id] = now.addingTimeInterval(retryAfter ?? Self.defaultBackOff)
            Log.fetch.notice("Claude usage API returned 429; backing off")
            if let usage = AccountUsage.newest(snapshot, cached) { return usage.with(plan: plan) }
            throw UsageError.rateLimited
        } catch {
            if let snapshot { return snapshot.with(plan: plan) }
            throw UsageError(error)
        }
    }

    /// Claude Code renews its token only while it runs. When this account has been idle that long, let the
    /// CLI renew it; after a failure, wait 15 minutes before the next try.
    private func renewed(_ account: AccountConfig, context: FetchContext) async -> ClaudeCredentials? {
        guard context.renewClaudeSignIns else { return nil }
        if let running = renewals[account.id] { return await running.value }
        if let failed = renewalFailedAt[account.id], Date.now.timeIntervalSince(failed) < Self.renewalRetryInterval {
            return nil
        }

        let task = Task { [credentials, renewer] () -> ClaudeCredentials? in
            // Claude Code may have renewed the token since the first read.
            if let fresh = try? await credentials.credentials(configDir: account.path), !fresh.isExpired() {
                return fresh
            }
            await renewer.renew(account)
            guard let fresh = try? await credentials.credentials(configDir: account.path), !fresh.isExpired() else {
                return nil
            }
            return fresh
        }
        renewals[account.id] = task
        let fresh = await task.value
        renewals[account.id] = nil
        renewalFailedAt[account.id] = fresh == nil ? .now : nil
        return fresh
    }

    private func notSignedIn(_ account: AccountConfig) async -> UsageError {
        let config = await configs.config(configDir: account.path)
        if config?.oauthAccount == nil, config?.hasAPIKey == true { return .apiKeyLogin }
        return .notSignedIn(.claude, loginCommand: account.loginCommand)
    }
}
