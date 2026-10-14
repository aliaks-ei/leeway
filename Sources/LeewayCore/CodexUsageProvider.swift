import Foundation

/// Reads Codex quota for one `CODEX_HOME` through `codex app-server` JSON-RPC
/// (`account/read` and `account/rateLimits/read`). The CLI makes the request with its own login,
/// so this app never touches Codex tokens.
public struct CodexUsageProvider: UsageProvider {
    private let locator: CLILocator
    private static let timeout: TimeInterval = 25

    public init(locator: CLILocator = .shared) {
        self.locator = locator
    }

    public func fetch(_ account: AccountConfig, cached: AccountUsage?, context: FetchContext) async throws -> AccountUsage {
        let home = account.path
        guard FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent("auth.json")) else {
            throw UsageError.notSignedIn(.codex, loginCommand: account.loginCommand)
        }
        guard let binary = await Self.binary(home: home, customPath: context.codexPath, locator: locator) else {
            throw UsageError.codexNotFound
        }
        let responses = try await CodexAppServer.request(binary: binary, home: home, calls: [
            .init(method: "account/read", params: [:]),
            .init(method: "account/rateLimits/read", params: nil),
        ], timeout: Self.timeout)
        return try Self.parse(account: responses[0], rateLimits: responses[1], loginCommand: account.loginCommand)
    }

    /// The CLI to run for `home`, in this order:
    /// 1. the path chosen in Settings;
    /// 2. the build the Codex app keeps in that home;
    /// 3. the usual install locations, then the copy inside the ChatGPT or Codex app, then the login shell.
    public static func binary(home: String, customPath: String?, locator: CLILocator = .shared) async -> String? {
        if let customPath { return CLILocator.isExecutable(customPath) ? customPath : nil }
        let daemon = "\(home)/packages/app-server-daemon/current/bin/codex"
        if CLILocator.isExecutable(daemon) { return daemon }
        return await sharedBinary(locator: locator)
    }

    /// The CLI found without a home-specific build, for the Settings window.
    public static func sharedBinary(locator: CLILocator = .shared) async -> String? {
        await locator.find("codex", last: [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ])
    }

    public static func parse(account accountData: Data, rateLimits rateLimitsData: Data, loginCommand: String) throws -> AccountUsage {
        let account = try? JSONDecoder().decode(AccountResponse.self, from: accountData)
        switch account?.type {
        case nil: throw UsageError.notSignedIn(.codex, loginCommand: loginCommand)
        case "apiKey": throw UsageError.apiKeyLogin
        default: break
        }
        let limits = try? JSONDecoder().decode(RateLimitsResponse.self, from: rateLimitsData)
        guard let snapshot = limits?.byLimitID?["codex"] ?? limits?.rateLimits else {
            throw UsageError.codexNoRateLimits
        }
        // Plans differ in which windows they have (Pro Lite has only a weekly one in `primary`),
        // so sort by window length instead of position: up to a day is the session window.
        var session: UsageWindow?
        var weekly: UsageWindow?
        for (isPrimary, limit) in [(true, snapshot.primary), (false, snapshot.secondary)] {
            guard let limit, let used = limit.usedPercent else { continue }
            let window = UsageWindow(usedPercent: used, resetsAt: limit.resetsAt)
            let isSession = limit.durationMinutes.map { $0 <= 24 * 60 } ?? isPrimary
            if isSession { session = session ?? window } else { weekly = weekly ?? window }
        }
        let email = account?.email
        return AccountUsage(
            session: session,
            weekly: weekly,
            plan: planName(account?.planType ?? snapshot.planType),
            measuredAt: .now,
            email: email,
            identity: email.map { "codex:\(account?.workspace ?? ""):\($0)" })
    }

    public static func planName(_ raw: String?) -> String? {
        guard let raw, raw != "unknown" else { return nil }
        switch raw {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based": return "Business"
        case "edu", "edu_plus", "edu_pro": return "Edu"
        case let value where value.hasPrefix("enterprise") || value == "ent26": return "Enterprise"
        default: return raw.capitalized
        }
    }

    /// The `account/read` result.
    private struct AccountResponse: Decodable {
        var type: String?
        var email: String?
        var planType: String?
        var workspace: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let account = container.nested(AccountKeys.self, .account)
            type = account?.string(.type)
            email = account?.string(.email)
            planType = account?.string(.planType)
            workspace = container.nested(RoutingKeys.self, .workspaceRouting)?.string(.chatgptAccountId)
        }

        private enum CodingKeys: String, CodingKey { case account, workspaceRouting }
        private enum AccountKeys: String, CodingKey { case type, email, planType }
        private enum RoutingKeys: String, CodingKey { case chatgptAccountId }
    }

    /// The `account/rateLimits/read` result.
    private struct RateLimitsResponse: Decodable {
        struct Snapshot: Decodable {
            var primary: Limit?
            var secondary: Limit?
            var planType: String?

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
                primary = container.lenient(Limit.self, .primary)
                secondary = container.lenient(Limit.self, .secondary)
                planType = container.string(.planType)
            }

            private enum CodingKeys: String, CodingKey { case primary, secondary, planType }
        }

        struct Limit: Decodable {
            var usedPercent: Double?
            var resetsAt: Date?
            var durationMinutes: Double?

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
                usedPercent = container.number(.usedPercent)
                resetsAt = container.date(.resetsAt)
                durationMinutes = container.number(.windowDurationMins)
            }

            private enum CodingKeys: String, CodingKey { case usedPercent, resetsAt, windowDurationMins }
        }

        var byLimitID: [String: Snapshot]?
        var rateLimits: Snapshot?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            byLimitID = container.lenient([String: Snapshot].self, .rateLimitsByLimitId)
            rateLimits = container.lenient(Snapshot.self, .rateLimits)
        }

        private enum CodingKeys: String, CodingKey { case rateLimitsByLimitId, rateLimits }
    }
}
