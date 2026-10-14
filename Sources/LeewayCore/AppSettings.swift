import Foundation
import Observation

/// Every choice made in Settings, in one place. Views bind to it, and the store reads it.
/// Each change is saved to `UserDefaults` at once, under the keys that earlier versions used.
@MainActor
@Observable
public final class AppSettings {
    public enum Key {
        public static let metric = "usageMetric"
        public static let menuBarMode = "menuBarMode"
        public static let menuBarWindow = "menuBarWindow"
        public static let refreshMinutes = "refreshMinutes"
        public static let compactCards = "compactCards"
        public static let renewClaudeSignIns = "renewClaudeSignIns"
        public static let codexPath = "codexPath"
        public static let overrides = "accountOverrides"
        public static let customFolders = "customFolders"
        public static let order = "accountOrder"

        static let all = [metric, menuBarMode, menuBarWindow, refreshMinutes, compactCards, renewClaudeSignIns,
                          codexPath, overrides, customFolders, order]
    }

    public static let refreshChoices = [2, 5, 10, 15, 30]

    @ObservationIgnored private let defaults: UserDefaults

    public var metric: UsageMetric { didSet { defaults.set(metric.rawValue, forKey: Key.metric) } }
    public var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: Key.menuBarMode) } }
    public var menuBarWindow: MenuBarWindow { didSet { defaults.set(menuBarWindow.rawValue, forKey: Key.menuBarWindow) } }
    public var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Key.refreshMinutes) } }
    public var compactCards: Bool { didSet { defaults.set(compactCards, forKey: Key.compactCards) } }
    /// Start `claude` to renew an expired sign-in (see `ClaudeCLIRenewer`).
    public var renewClaudeSignIns: Bool { didSet { defaults.set(renewClaudeSignIns, forKey: Key.renewClaudeSignIns) } }
    /// A Codex CLI chosen in Settings. Empty means find it automatically.
    public var codexPath: String { didSet { defaults.set(codexPath, forKey: Key.codexPath) } }
    /// Per-account choices, keyed by `AccountConfig.id`.
    public var overrides: [String: AccountOverride] { didSet { Self.encode(overrides, Key.overrides, defaults) } }
    public var customFolders: [CustomFolder] { didSet { Self.encode(customFolders, Key.customFolders, defaults) } }
    /// Account IDs in display order.
    public var order: [String] { didSet { defaults.set(order, forKey: Key.order) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        metric = defaults.string(forKey: Key.metric).flatMap(UsageMetric.init) ?? .used
        menuBarMode = defaults.string(forKey: Key.menuBarMode).flatMap(MenuBarMode.init) ?? .firstPerProvider
        menuBarWindow = defaults.string(forKey: Key.menuBarWindow).flatMap(MenuBarWindow.init) ?? .sessionFirst
        let minutes = defaults.integer(forKey: Key.refreshMinutes)
        refreshMinutes = minutes > 0 ? minutes : 5
        compactCards = defaults.bool(forKey: Key.compactCards)
        renewClaudeSignIns = defaults.object(forKey: Key.renewClaudeSignIns) as? Bool ?? true
        codexPath = defaults.string(forKey: Key.codexPath) ?? ""
        overrides = Self.decode(Key.overrides, defaults) ?? [:]
        customFolders = Self.decode(Key.customFolders, defaults) ?? []
        order = defaults.stringArray(forKey: Key.order) ?? []
    }

    /// The Codex CLI chosen in Settings, with `~` expanded. Nil means find it automatically.
    public var resolvedCodexPath: String? {
        codexPath.isEmpty ? nil : (codexPath as NSString).expandingTildeInPath
    }

    public var fetchContext: FetchContext {
        FetchContext(renewClaudeSignIns: renewClaudeSignIns, codexPath: resolvedCodexPath)
    }

    public func override(for id: String) -> AccountOverride {
        overrides[id] ?? AccountOverride()
    }

    /// Changes the choices for one account. An override with only default values is removed.
    public func updateOverride(for id: String, _ change: (inout AccountOverride) -> Void) {
        var value = override(for: id)
        change(&value)
        overrides[id] = value == AccountOverride() ? nil : value
    }

    private static func decode<T: Decodable>(_ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encode(_ value: some Encodable, _ key: String, _ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    // MARK: Earlier names

    /// Bundle IDs of earlier builds, newest first: Leeway 0.3–0.4, "AI Usage Bar" 0.2, then the 0.1 builds.
    private static let legacyDomains = ["com.leewayapp.Leeway", "app.aiusagebar.AIUsageBar", "com.aliakseimazheika.AIUsageBar"]
    private static let migratedKey = "migratedLegacyDefaults"

    /// Copies the settings of an earlier build once, so the order, names and choices survive the rename.
    public static func migrateLegacyDefaults(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        moveLegacySupportFolder()

        for domain in legacyDomains where domain != Bundle.main.bundleIdentifier {
            guard let legacy = UserDefaults(suiteName: domain),
                  Key.all.contains(where: { legacy.object(forKey: $0) != nil })
            else { continue }
            for key in Key.all where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            // The 0.1 builds named ~/.codex "Personal"; the scan would now name it after the login email.
            if domain == legacyDomains.last {
                let codexID = AccountConfig.id(provider: .codex, path: NSHomeDirectory() + "/.codex")
                var overrides: [String: AccountOverride] = decode(Key.overrides, defaults) ?? [:]
                if overrides[codexID] == nil {
                    overrides[codexID] = AccountOverride(name: "Personal")
                    encode(overrides, Key.overrides, defaults)
                }
            }
            return
        }
    }

    /// `~/Library/Application Support/AIUsageBar` holds the reading cache and Claude statusline snapshots.
    private static func moveLegacySupportFolder() {
        let legacy = AppPaths.supportDir.deletingLastPathComponent().appendingPathComponent("AIUsageBar", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: AppPaths.supportDir.path) else { return }
        try? manager.moveItem(at: legacy, to: AppPaths.supportDir)
    }
}
