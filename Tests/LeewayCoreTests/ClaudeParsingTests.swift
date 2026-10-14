import Foundation
@testable import LeewayCore
import Testing

struct ClaudeUsageParsingTests {
    @Test func readsLimitsArrayWithScopedModels() throws {
        let json = """
        {"limits": [
          {"kind": "session", "percent": 42.5, "resets_at": "2026-10-12T15:00:00.123Z"},
          {"kind": "weekly_all", "percent": "17", "resets_at": 1791900000},
          {"kind": "weekly_scoped", "percent": 80, "scope": {"model": {"display_name": "Fable"}}},
          {"kind": "weekly_scoped", "percent": 90, "scope": {"model": {"display_name": "Fable"}}},
          {"kind": "weekly_scoped", "percent": 5},
          {"kind": "unknown", "percent": 1},
          "not an object"
        ]}
        """
        let usage = try ClaudeHTTPUsageClient.parse(Data(json.utf8))
        #expect(usage.session?.usedPercent == 42.5)
        #expect(usage.session?.resetsAt == FlexibleDate.parse("2026-10-12T15:00:00.123Z"))
        #expect(usage.weekly?.usedPercent == 17)
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_791_900_000))
        #expect(usage.scoped == [ScopedWindow(name: "Fable", window: UsageWindow(usedPercent: 80))])
    }

    @Test func fallsBackToLegacyWindows() throws {
        let json = """
        {"five_hour": {"utilization": 12, "resets_at": "2026-10-12T15:00:00Z"},
         "seven_day": {"utilization": 3.5, "resets_at": null}, "seven_day_opus": null}
        """
        let usage = try ClaudeHTTPUsageClient.parse(Data(json.utf8))
        #expect(usage.session?.usedPercent == 12)
        #expect(usage.weekly == UsageWindow(usedPercent: 3.5))
        #expect(usage.scoped == nil)
    }

    @Test func rejectsNonObjectResponse() {
        #expect(throws: UsageError.unexpectedResponse) { try ClaudeHTTPUsageClient.parse(Data("[]".utf8)) }
    }

    @Test func readsRetryAfterSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ClaudeHTTPUsageClient.retryAfter("120", now: now) == 120)
        #expect(ClaudeHTTPUsageClient.retryAfter(nil, now: now) == nil)
        let date = "Mon, 12 Jan 1970 13:48:40 GMT" // 1_000_120
        #expect(ClaudeHTTPUsageClient.retryAfter(date, now: now) == 120)
    }
}

struct ClaudeCredentialsTests {
    private let json = """
    {"claudeAiOauth": {"accessToken": "tok", "expiresAt": 1791900000000, "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}
    """

    @Test func parsesJSON() throws {
        let credentials = try ClaudeCredentials.parse(json)
        #expect(credentials.accessToken == "tok")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_791_900_000))
        #expect(credentials.planName == "Max 20x")
    }

    @Test func parsesHexEncodedJSON() throws {
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(try ClaudeCredentials.parse(hex + "\n").accessToken == "tok")
    }

    @Test func rejectsLoginWithoutToken() {
        #expect(throws: UsageError.incompleteClaudeLogin) { try ClaudeCredentials.parse(#"{"claudeAiOauth": {}}"#) }
        #expect(throws: UsageError.incompleteClaudeLogin) { try ClaudeCredentials.parse("garbage") }
    }

    @Test func expiresOneMinuteEarly() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(ClaudeCredentials(accessToken: "t", expiresAt: now.addingTimeInterval(30)).isExpired(now: now))
        #expect(!ClaudeCredentials(accessToken: "t", expiresAt: now.addingTimeInterval(120)).isExpired(now: now))
        #expect(!ClaudeCredentials(accessToken: "t", expiresAt: nil).isExpired(now: now))
    }

    @Test func namesPlans() {
        #expect(ClaudePlan.name(subscription: "max", tier: "x_5x") == "Max 5x")
        #expect(ClaudePlan.name(subscription: "pro", tier: nil) == "Pro")
        #expect(ClaudePlan.name(subscription: "", tier: nil) == nil)
        #expect(ClaudePlan.name(subscription: "startup", tier: nil) == "Startup")
    }
}

struct ClaudePathsTests {
    @Test func hashesLikeClaudeCode() {
        // printf '%s' /Users/me/.claude-work | shasum -a 256 | cut -c1-8
        #expect(ClaudePaths.hash("/Users/me/.claude-work") == "1e91dd84")
    }

    @Test func namesKeychainItems() {
        let home = "/Users/me"
        #expect(ClaudePaths.keychainServices(configDir: "/Users/me/.claude", home: home)
            == ["Claude Code-credentials", "Claude Code-credentials-\(ClaudePaths.hash("/Users/me/.claude"))"])
        #expect(ClaudePaths.keychainServices(configDir: "/Users/me/.claude-work", home: home)
            == ["Claude Code-credentials-1e91dd84"])
    }

    @Test func placesConfigFile() {
        let home = "/Users/me"
        #expect(ClaudePaths.configFile(configDir: "/Users/me/.claude", home: home).path == "/Users/me/.claude.json")
        #expect(ClaudePaths.configFile(configDir: "/Users/me/.claude-work", home: home).path == "/Users/me/.claude-work/.claude.json")
    }
}

struct ClaudeSnapshotTests {
    @Test func readsStatuslineSnapshot() {
        let json = """
        {"config_dir": "/x", "captured_at": 1791900000.5,
         "five_hour": {"used_percentage": 64, "resets_at": 1791910000}, "seven_day": null}
        """
        let usage = ClaudeSnapshot.parse(Data(json.utf8))
        #expect(usage?.session == UsageWindow(usedPercent: 64, resetsAt: Date(timeIntervalSince1970: 1_791_910_000)))
        #expect(usage?.weekly == nil)
        #expect(usage?.measuredAt == Date(timeIntervalSince1970: 1_791_900_000.5))
    }

    @Test func ignoresSnapshotWithoutWindows() {
        #expect(ClaudeSnapshot.parse(Data(#"{"captured_at": 1, "five_hour": null}"#.utf8)) == nil)
    }
}

struct ClaudeConfigTests {
    @Test func readsAccountAndPlan() throws {
        let json = """
        {"projects": {"/a": {"history": [1, 2, 3]}},
         "oauthAccount": {"emailAddress": "a@b.c", "accountUuid": "u1", "organizationUuid": "o1", "organizationType": "claude_max"}}
        """
        let config = try JSONDecoder().decode(ClaudeConfigFile.self, from: Data(json.utf8))
        #expect(config.oauthAccount?.emailAddress == "a@b.c")
        #expect(config.identity == "claude:u1:o1")
        #expect(config.planName == "Max")
        #expect(!config.hasAPIKey)
    }

    @Test func detectsAPIKeyLogin() throws {
        let config = try JSONDecoder().decode(ClaudeConfigFile.self, from: Data(#"{"primaryApiKey": "sk"}"#.utf8))
        #expect(config.oauthAccount == nil)
        #expect(config.hasAPIKey)
    }
}
