import CryptoKit
import Foundation

/// Where Claude Code keeps things for one `CLAUDE_CONFIG_DIR`.
public enum ClaudePaths {
    /// `~/.claude.json` for the default folder, `<dir>/.claude.json` when `CLAUDE_CONFIG_DIR` is set.
    public static func configFile(configDir: String, home: String = NSHomeDirectory()) -> URL {
        if configDir == home + "/.claude" {
            return URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        }
        return URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
    }

    /// Claude Code names the Keychain item `Claude Code-credentials` for the default `~/.claude`, and
    /// `Claude Code-credentials-<first 8 hex of sha256(config dir)>` when `CLAUDE_CONFIG_DIR` is set.
    public static func keychainServices(configDir: String, home: String = NSHomeDirectory()) -> [String] {
        let hashed = "Claude Code-credentials-\(hash(configDir))"
        return configDir == home + "/.claude" ? ["Claude Code-credentials", hashed] : [hashed]
    }

    /// First 8 hex digits of the SHA-256 of the path, as Claude Code computes it.
    public static func hash(_ configDir: String) -> String {
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    /// The statusline snapshot for the folder. `claude-statusline-snapshot.sh` hashes the folder with
    /// symbolic links resolved (`pwd -P`), so the app does the same.
    public static func snapshotURL(configDir: String, directory: URL = AppPaths.claudeSnapshotsDir) -> URL {
        directory.appendingPathComponent("\(hash(PathDisplay.canonical(configDir))).json")
    }
}

/// The parts of `.claude.json` that the app reads. The file also holds project history and can be
/// several MB, so `ClaudeConfigStore` parses each version of it once.
public struct ClaudeConfigFile: Decodable, Equatable, Sendable {
    public struct OAuthAccount: Decodable, Equatable, Sendable {
        public var emailAddress: String?
        public var accountUuid: String?
        public var organizationUuid: String?
        /// For example `claude_pro`.
        public var organizationType: String?

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            emailAddress = container.string(.emailAddress)
            accountUuid = container.string(.accountUuid)
            organizationUuid = container.string(.organizationUuid)
            organizationType = container.string(.organizationType)
        }

        private enum CodingKeys: String, CodingKey {
            case emailAddress, accountUuid, organizationUuid, organizationType
        }
    }

    /// The signed-in account. It is absent after `/logout`.
    public var oauthAccount: OAuthAccount?
    public var hasAPIKey: Bool

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        oauthAccount = container.lenient(OAuthAccount.self, .oauthAccount)
        hasAPIKey = container.string(.primaryApiKey) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case oauthAccount, primaryApiKey
    }

    /// `claude:<account>:<organization>`, the same for two folders signed in to the same account.
    public var identity: String? {
        guard let user = oauthAccount?.accountUuid else { return nil }
        return "claude:\(user):\(oauthAccount?.organizationUuid ?? "")"
    }

    /// Fallback plan name from `organizationType`.
    public var planName: String? {
        guard let type = oauthAccount?.organizationType else { return nil }
        return ClaudePlan.name(subscription: type.replacingOccurrences(of: "claude_", with: ""), tier: nil)
    }
}

/// Reads `.claude.json` files and keeps each one parsed until the file changes.
public actor ClaudeConfigStore {
    private struct Entry {
        var modified: Date?
        var size: Int?
        var config: ClaudeConfigFile?
    }

    private let home: String
    private var entries: [String: Entry] = [:]

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func config(configDir: String) -> ClaudeConfigFile? {
        let url = ClaudePaths.configFile(configDir: configDir, home: home)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if let entry = entries[url.path], entry.modified == values?.contentModificationDate, entry.size == values?.fileSize {
            return entry.config
        }
        let config = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ClaudeConfigFile.self, from: $0) }
        entries[url.path] = Entry(modified: values?.contentModificationDate, size: values?.fileSize, config: config)
        return config
    }

    /// When Claude Code last wrote the folder's config file.
    public func lastModified(configDir: String) -> Date? {
        let url = ClaudePaths.configFile(configDir: configDir, home: home)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

public enum ClaudePlan {
    public static func name(subscription: String?, tier: String?) -> String? {
        guard let subscription = subscription?.lowercased(), !subscription.isEmpty else { return nil }
        let tier = tier?.lowercased() ?? ""
        switch subscription {
        case "max": return tier.contains("20x") ? "Max 20x" : tier.contains("5x") ? "Max 5x" : "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return subscription.capitalized
        }
    }
}
