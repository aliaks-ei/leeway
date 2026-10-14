import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
    /// The default config folder name: `~/.claude` or `~/.codex`.
    public var defaultFolder: String { self == .claude ? ".claude" : ".codex" }
    /// The variable that points the CLI at another config folder.
    public var homeVariable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
}

/// One account to watch. `path` is the absolute `CLAUDE_CONFIG_DIR` or `CODEX_HOME` of that account.
public struct AccountConfig: Codable, Identifiable, Hashable, Sendable {
    public var provider: Provider
    public var name: String
    public var path: String
    /// True for `~/.claude` and `~/.codex`, which the CLIs use when no config dir is set.
    public var isDefaultFolder: Bool
    /// Login email, when the config folder or the last reading reports it.
    public var email: String?
    /// Same value for two folders signed in to the same account; they share one quota.
    public var identity: String?
    /// Added by hand in Settings, not found by the folder scan.
    public var isCustom: Bool
    public var isHidden: Bool
    /// Name of the account that has the same login. Such an account is not shown or fetched.
    public var duplicateOf: String?
    /// When the CLI last wrote the folder's login file; picks which of two duplicate folders to keep.
    public var lastUsed: Date?

    public init(provider: Provider, name: String = "", path: String, isDefaultFolder: Bool = false, email: String? = nil,
                identity: String? = nil, isCustom: Bool = false, isHidden: Bool = false, duplicateOf: String? = nil,
                lastUsed: Date? = nil) {
        self.provider = provider
        self.name = name
        self.path = path
        self.isDefaultFolder = isDefaultFolder
        self.email = email
        self.identity = identity
        self.isCustom = isCustom
        self.isHidden = isHidden
        self.duplicateOf = duplicateOf
        self.lastUsed = lastUsed
    }

    public static func id(provider: Provider, path: String) -> String { "\(provider.rawValue):\(path)" }

    public var id: String { Self.id(provider: provider, path: path) }
    /// The path with `~` for the home folder, for display.
    public var displayPath: String { PathDisplay.abbreviate(path) }
    public var isVisible: Bool { !isHidden && duplicateOf == nil }

    /// The command that signs this account in, with the config dir variable when it is not the default folder.
    /// The path is quoted, so the command works when the user copies it.
    public var loginCommand: String {
        let command = provider == .claude ? "claude" : "codex login"
        return isDefaultFolder ? command : "\(provider.homeVariable)=\(ShellQuote.path(path)) \(command)"
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// A window whose reset time has passed since the reading started again from zero.
    public func hasReset(now: Date = .now) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public func effectiveUsed(now: Date = .now) -> Double {
        hasReset(now: now) ? 0 : min(max(usedPercent, 0), 100)
    }
}

/// A weekly window that counts one model only, such as Claude's Fable limit.
public struct ScopedWindow: Codable, Equatable, Sendable {
    /// The server's label for the model, e.g. "Fable".
    public var name: String
    public var window: UsageWindow

    public init(name: String, window: UsageWindow) {
        self.name = name
        self.window = window
    }
}

public struct AccountUsage: Codable, Equatable, Sendable {
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var plan: String?
    public var measuredAt: Date
    public var email: String?
    public var identity: String?
    /// Per-model weekly windows, in the server's order. Nil when the source does not report them
    /// (Codex, the Claude statusline snapshot).
    public var scoped: [ScopedWindow]?

    public init(session: UsageWindow? = nil, weekly: UsageWindow? = nil, plan: String? = nil, measuredAt: Date,
                email: String? = nil, identity: String? = nil, scoped: [ScopedWindow]? = nil) {
        self.session = session
        self.weekly = weekly
        self.plan = plan
        self.measuredAt = measuredAt
        self.email = email
        self.identity = identity
        self.scoped = scoped
    }

    /// Used % of the window the menu bar shows for this account.
    public func menuBarUsed(_ preference: MenuBarWindow, now: Date = .now) -> Double? {
        let session = session?.effectiveUsed(now: now)
        let weekly = weekly?.effectiveUsed(now: now)
        return switch preference {
        case .sessionFirst: session ?? weekly
        case .weeklyFirst: weekly ?? session
        case .closest: [session, weekly].compactMap { $0 }.max()
        }
    }

    public func with(plan: String?) -> AccountUsage {
        var copy = self
        copy.plan = plan ?? copy.plan
        return copy
    }

    public func with(scoped: [ScopedWindow]?) -> AccountUsage {
        var copy = self
        copy.scoped = scoped ?? copy.scoped
        return copy
    }

    /// The reading measured last, or whichever exists.
    public static func newest(_ a: AccountUsage?, _ b: AccountUsage?) -> AccountUsage? {
        switch (a, b) {
        case let (a?, b?): a.measuredAt >= b.measuredAt ? a : b
        default: a ?? b
        }
    }
}

public struct AccountState: Equatable, Sendable {
    public var usage: AccountUsage?
    public var error: UsageError?
    public var isRefreshing: Bool

    public init(usage: AccountUsage? = nil, error: UsageError? = nil, isRefreshing: Bool = false) {
        self.usage = usage
        self.error = error
        self.isRefreshing = isRefreshing
    }

    /// Whether the last reading worked, for choosing between duplicate folders. Nil when unknown.
    public var worked: Bool? {
        if let error { return error.kind != .failure && usage == nil ? nil : false }
        return usage != nil ? true : nil
    }
}

/// Whether percentages show quota used or quota left, in the menu bar and the popover.
public enum UsageMetric: String, CaseIterable, Identifiable, Sendable {
    case used
    case left

    public var id: String { rawValue }
    public var title: String { self == .used ? "Used" : "Left" }

    public func value(used: Double) -> Double {
        self == .used ? used : 100 - used
    }
}

/// Which accounts the menu bar shows.
public enum MenuBarMode: String, CaseIterable, Identifiable, Sendable {
    case firstPerProvider
    case closest
    case chosen
    case iconOnly

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .firstPerProvider: "Top account of each provider"
        case .closest: "Account closest to its limit"
        case .chosen: "Accounts I choose"
        case .iconOnly: "Icon only"
        }
    }
}

/// Which limit window the menu bar shows for an account.
public enum MenuBarWindow: String, CaseIterable, Identifiable, Sendable {
    case sessionFirst
    case weeklyFirst
    case closest

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sessionFirst: "5-hour, else weekly"
        case .weeklyFirst: "Weekly, else 5-hour"
        case .closest: "Whichever is closer to its limit"
        }
    }
}

/// Per-account choices made in Settings, keyed by `AccountConfig.id`.
public struct AccountOverride: Codable, Equatable, Sendable {
    public var name: String?
    public var hidden = false
    public var inMenuBar = false

    public init(name: String? = nil, hidden: Bool = false, inMenuBar: Bool = false) {
        self.name = name
        self.hidden = hidden
        self.inMenuBar = inMenuBar
    }
}

/// A config folder added by hand because the scan does not find it. `home` may start with `~`.
public struct CustomFolder: Codable, Hashable, Sendable {
    public var provider: Provider
    public var home: String

    public init(provider: Provider, home: String) {
        self.provider = provider
        self.home = home
    }

    public var path: String { (home as NSString).expandingTildeInPath }
    public var accountID: String { AccountConfig.id(provider: provider, path: path) }
}

/// The Settings choices a fetch needs. The fetchers get a copy, so they never read the settings store.
public struct FetchContext: Sendable {
    public var renewClaudeSignIns: Bool
    /// A Codex CLI chosen in Settings. Nil means find it automatically.
    public var codexPath: String?

    public init(renewClaudeSignIns: Bool = true, codexPath: String? = nil) {
        self.renewClaudeSignIns = renewClaudeSignIns
        self.codexPath = codexPath
    }
}

public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "io.github.aliaks-ei.Leeway"
    }

    /// `LeewayReleasesURL` in Info.plist; "Check for Updates" opens it when Sparkle is not set up.
    public static var releasesURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "LeewayReleasesURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}

public enum AppPaths {
    public static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Leeway", isDirectory: true)
    }()

    public static var cacheFile: URL { supportDir.appendingPathComponent("cache.json") }
    public static var claudeSnapshotsDir: URL { supportDir.appendingPathComponent("claude-snapshots", isDirectory: true) }
    /// The empty, never-trusted folder that `claude` starts in to renew a sign-in.
    public static var claudeRenewDir: URL { supportDir.appendingPathComponent("claude-renew", isDirectory: true) }
}

public enum PathDisplay {
    /// `/Users/me/.claude-work` → `~/.claude-work`.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The path with symbolic links resolved, as `pwd -P` prints it. The path itself when it does not exist.
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum ShellQuote {
    /// The text as one shell word: unchanged when it has only safe characters, otherwise in single quotes.
    public static func quote(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-+:@%")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A path as a shell word, with `~/` kept outside the quotes so the shell still expands it.
    public static func path(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path.hasPrefix(home + "/") else { return quote(path) }
        return "~/" + quote(String(path.dropFirst(home.count + 1)))
    }
}
