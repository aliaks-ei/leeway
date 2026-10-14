import Foundation

/// The parts of Claude Code's stored login that the app uses. The token stays in memory only.
public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date?
    public var planName: String?

    public init(accessToken: String, expiresAt: Date? = nil, planName: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.planName = planName
    }

    /// True from one minute before `expiresAt`, so a request never starts with a token that expires on the way.
    public func isExpired(now: Date = .now, margin: TimeInterval = 60) -> Bool {
        expiresAt.map { $0.addingTimeInterval(-margin) <= now } ?? false
    }

    /// The JSON that Claude Code stores, as text or hex-encoded text.
    public static func parse(_ stored: String) throws -> ClaudeCredentials {
        var text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{"), let decoded = Data(hexString: text), let string = String(data: decoded, encoding: .utf8) {
            text = string
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8)),
              let oauth = stored.claudeAiOauth, let token = oauth.accessToken, !token.isEmpty
        else {
            throw UsageError.incompleteClaudeLogin
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            planName: ClaudePlan.name(subscription: oauth.subscriptionType, tier: oauth.rateLimitTier))
    }

    private struct Stored: Decodable {
        struct OAuth: Decodable {
            var accessToken: String?
            /// Unix milliseconds.
            var expiresAt: Double?
            var subscriptionType: String?
            var rateLimitTier: String?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                accessToken = container.string(.accessToken)
                expiresAt = container.number(.expiresAt)
                subscriptionType = container.string(.subscriptionType)
                rateLimitTier = container.string(.rateLimitTier)
            }

            private enum CodingKeys: String, CodingKey {
                case accessToken, expiresAt, subscriptionType, rateLimitTier
            }
        }

        var claudeAiOauth: OAuth?
    }
}

/// Where the fetcher gets the Claude login. Tests use a fake.
public protocol ClaudeCredentialSource: Sendable {
    /// Nil when the folder has no Claude login.
    func credentials(configDir: String) async throws -> ClaudeCredentials?
}

/// Reads the login that Claude Code keeps in the Keychain, through `/usr/bin/security`: the item's access
/// list trusts that tool, so the user sees no Keychain prompt. Falls back to `<config dir>/.credentials.json`,
/// where Claude Code writes the login when the Keychain is not available.
public struct KeychainCredentialSource: ClaudeCredentialSource {
    private let home: String
    /// A locked Keychain can show a dialog; do not wait for it longer than this.
    private static let timeout: TimeInterval = 15

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func credentials(configDir: String) async throws -> ClaudeCredentials? {
        for service in ClaudePaths.keychainServices(configDir: configDir, home: home) {
            let result: Subprocess.Output
            do {
                result = try await Subprocess.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"],
                                                  timeout: Self.timeout)
            } catch Subprocess.Failure.timedOut {
                throw UsageError.keychainTimedOut
            }
            if result.status == 0 { return try ClaudeCredentials.parse(result.stdout) }
        }
        let file = URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try ClaudeCredentials.parse(String(decoding: data, as: UTF8.self))
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2), hexString.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
