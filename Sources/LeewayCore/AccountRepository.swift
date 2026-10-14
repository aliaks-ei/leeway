import Foundation

/// Finds Claude Code and Codex config folders in the home folder, off the main thread:
/// `~/.claude` and `~/.codex`, plus any `~/.claude*` or `~/.codex*` folder that holds a login,
/// such as `~/.claude-work` used with `CLAUDE_CONFIG_DIR`, plus the folders added in Settings.
///
/// The scan only reads the disk. Names, order, hidden state and duplicates come from
/// `AccountArrangement`, which is fast enough to run on each Settings change.
public actor AccountRepository {
    private let home: String
    private let configs: ClaudeConfigStore

    public init(home: String = NSHomeDirectory(), configs: ClaudeConfigStore) {
        self.home = home
        self.configs = configs
    }

    public func scan(customFolders: [CustomFolder]) async -> [AccountConfig] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        var found: [AccountConfig] = []
        for provider in Provider.allCases {
            let folders = names
                .filter { $0.hasPrefix(provider.defaultFolder) && $0 != provider.defaultFolder && isDirectory(home + "/" + $0) }
                .sorted()
            for name in [provider.defaultFolder] + folders {
                if let account = await account(provider: provider, path: home + "/" + name) { found.append(account) }
            }
        }
        for custom in customFolders where !found.contains(where: { $0.id == custom.accountID }) {
            var account = await account(provider: custom.provider, path: custom.path)
                ?? AccountConfig(provider: custom.provider, path: custom.path)
            account.isCustom = true
            found.append(account)
        }
        Log.discovery.debug("Scan found \(found.count) folders")
        return found
    }

    /// The account in the folder at `path`, or nil when the folder has no login.
    private func account(provider: Provider, path: String) async -> AccountConfig? {
        var account = AccountConfig(provider: provider, path: path, isDefaultFolder: path == home + "/" + provider.defaultFolder)
        switch provider {
        case .claude:
            guard let oauth = await configs.config(configDir: path)?.oauthAccount else { return nil }
            account.email = oauth.emailAddress
            account.identity = await configs.config(configDir: path)?.identity
            account.lastUsed = await configs.lastModified(configDir: path)
        case .codex:
            let auth = URL(fileURLWithPath: path).appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: auth.path) else { return nil }
            account.lastUsed = (try? auth.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return account
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The provider whose files `folder` holds, or nil when it looks like neither.
    public static func detectProvider(folder: URL) -> Provider? {
        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        if has("auth.json") || has("config.toml") { return .codex }
        if has(".claude.json") || has("settings.json") || has("projects") { return .claude }
        let name = folder.lastPathComponent.lowercased()
        if name.contains("codex") { return .codex }
        if name.contains("claude") { return .claude }
        return nil
    }
}

/// Turns scanned folders into the account list: names, Settings choices, order and duplicate logins.
public enum AccountArrangement {
    /// All accounts in display order. `cached` supplies Codex emails and identities, which are known only
    /// after a reading. `worked` tells, per account ID, whether its last reading worked; it decides between
    /// duplicates.
    public static func arrange(_ scanned: [AccountConfig], overrides: [String: AccountOverride], order: [String],
                               cached: [String: AccountUsage], worked: [String: Bool] = [:]) -> [AccountConfig] {
        var accounts = scanned.map { found -> AccountConfig in
            var account = found
            let usage = cached[account.id]
            account.email = account.email ?? usage?.email
            account.identity = account.identity ?? usage?.identity
            let override = overrides[account.id]
            account.name = override?.name ?? autoName(account)
            account.isHidden = override?.hidden ?? false
            account.duplicateOf = nil
            return account
        }
        accounts = applyOrder(accounts, saved: order)
        return resolveDuplicates(accounts, worked: worked)
    }

    /// Saved order first; accounts that are not in it yet keep their scan order at the end.
    public static func applyOrder(_ accounts: [AccountConfig], saved: [String]) -> [AccountConfig] {
        let positions = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.enumerated().sorted { a, b in
            let ia = positions[a.element.id] ?? saved.count + a.offset
            let ib = positions[b.element.id] ?? saved.count + b.offset
            return ia < ib
        }.map(\.element)
    }

    /// Two folders signed in to the same account share one quota, so show one of them. Prefer the one whose
    /// last reading worked (the other usually holds an expired login), then the one not tried yet, then the
    /// one the CLI wrote last.
    public static func resolveDuplicates(_ accounts: [AccountConfig], worked: [String: Bool]) -> [AccountConfig] {
        func rank(_ account: AccountConfig) -> (Int, Date) {
            let health = worked[account.id].map { $0 ? 2 : 0 } ?? 1
            return (health, account.lastUsed ?? .distantPast)
        }
        var result = accounts
        var kept: [String: Int] = [:]
        for index in result.indices where !result[index].isHidden {
            guard let identity = result[index].identity else { continue }
            guard let other = kept[identity] else {
                kept[identity] = index
                continue
            }
            kept[identity] = rank(result[index]) > rank(result[other]) ? index : other
        }
        for index in result.indices where !result[index].isHidden {
            guard let identity = result[index].identity, let keep = kept[identity], keep != index else { continue }
            result[index].duplicateOf = result[keep].name
        }
        return result
    }

    /// `~/.claude-work` → "Work". The default folder, which has no suffix, uses the login email.
    public static func autoName(_ account: AccountConfig) -> String {
        var name = (account.path as NSString).lastPathComponent.lowercased()
        for prefix in [".", account.provider.rawValue, "-", "_", "."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        name = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if !name.isEmpty { return name.capitalized }
        return account.email ?? "Default"
    }
}
