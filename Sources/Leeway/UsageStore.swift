import Foundation
import LeewayCore
import Observation

/// The state the views show: accounts, readings and refresh status. Disk and network work happens in
/// `AccountRepository` and the providers; this type only coordinates them and keeps the results.
@MainActor
@Observable
final class UsageStore {
    /// Every account found, in display order, including hidden ones and duplicate logins (for Settings).
    private(set) var allAccounts: [AccountConfig] = []
    /// The accounts the popover shows and the app fetches.
    private(set) var accounts: [AccountConfig] = []
    private(set) var states: [String: AccountState] = [:]
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let repository: AccountRepository
    @ObservationIgnored private let providers: [Provider: any UsageProvider]
    @ObservationIgnored private let configs: ClaudeConfigStore
    @ObservationIgnored private let cache: UsageCache
    /// The last folder scan, before names, order and Settings choices are applied.
    @ObservationIgnored private var scanned: [AccountConfig] = []

    init(settings: AppSettings, repository: AccountRepository, providers: [Provider: any UsageProvider],
         configs: ClaudeConfigStore, cache: UsageCache) {
        self.settings = settings
        self.repository = repository
        self.providers = providers
        self.configs = configs
        self.cache = cache
        for (id, usage) in cache.load() {
            states[id] = AccountState(usage: usage)
        }
    }

    static func live(settings: AppSettings) -> UsageStore {
        let configs = ClaudeConfigStore()
        return UsageStore(
            settings: settings,
            repository: AccountRepository(configs: configs),
            providers: [.claude: ClaudeUsageProvider.live(configs: configs), .codex: CodexUsageProvider()],
            configs: configs,
            cache: UsageCache())
    }

    func accounts(for provider: Provider) -> [AccountConfig] {
        accounts.filter { $0.provider == provider }
    }

    func state(_ account: AccountConfig) -> AccountState {
        states[account.id] ?? AccountState()
    }

    // MARK: Accounts

    /// Scans the folders again (off the main thread) and applies the Settings choices.
    func rescan() async {
        scanned = await repository.scan(customFolders: settings.customFolders)
        arrange()
    }

    /// Applies names, order, hidden state and duplicates to the last scan. Fast; no disk access.
    private func arrange() {
        let all = AccountArrangement.arrange(
            scanned, overrides: settings.overrides, order: settings.order,
            cached: states.compactMapValues(\.usage), worked: states.compactMapValues(\.worked))
        if all != allAccounts { allAccounts = all }
        let visible = all.filter(\.isVisible)
        if visible != accounts { accounts = visible }
    }

    // MARK: Menu bar

    struct MenuBarItem: Equatable {
        var provider: Provider
        var used: Double?
    }

    func menuBarAccounts() -> [AccountConfig] {
        menuBarAccounts(mode: settings.menuBarMode)
    }

    private func menuBarAccounts(mode: MenuBarMode) -> [AccountConfig] {
        switch mode {
        case .firstPerProvider:
            return Provider.allCases.compactMap { accounts(for: $0).first }
        case .closest:
            let ranked = accounts.max { (used($0) ?? -1) < (used($1) ?? -1) }
            return ranked.map { [$0] } ?? []
        case .chosen:
            let chosen = accounts.filter { settings.override(for: $0.id).inMenuBar }
            return chosen.isEmpty ? menuBarAccounts(mode: .firstPerProvider) : chosen
        case .iconOnly:
            return []
        }
    }

    func menuBarItems() -> [MenuBarItem] {
        menuBarAccounts().map { MenuBarItem(provider: $0.provider, used: used($0)) }
    }

    /// The marker is useful only when some accounts are left out of the menu bar.
    func showsMenuBarMarker(_ account: AccountConfig) -> Bool {
        let shown = menuBarAccounts()
        return shown.count < accounts.count && shown.contains(account)
    }

    private func used(_ account: AccountConfig) -> Double? {
        states[account.id]?.usage?.menuBarUsed(settings.menuBarWindow)
    }

    // MARK: Settings

    func setName(_ name: String, for account: AccountConfig) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        settings.updateOverride(for: account.id) { $0.name = trimmed.isEmpty ? nil : trimmed }
        arrange()
    }

    func setHidden(_ hidden: Bool, for account: AccountConfig) {
        settings.updateOverride(for: account.id) { $0.hidden = hidden }
        arrange()
        if !hidden { Task { await refresh([account]) } }
    }

    func setInMenuBar(_ inMenuBar: Bool, for account: AccountConfig) {
        settings.updateOverride(for: account.id) { $0.inMenuBar = inMenuBar }
    }

    func isChosenForMenuBar(_ account: AccountConfig) -> Bool {
        settings.override(for: account.id).inMenuBar
    }

    enum AddFolderResult {
        case added
        case alreadyListed
        case unknownFolder
    }

    func addFolder(_ url: URL) async -> AddFolderResult {
        guard let provider = AccountRepository.detectProvider(folder: url) else { return .unknownFolder }
        let id = AccountConfig.id(provider: provider, path: url.path)
        if let existing = allAccounts.first(where: { $0.id == id }) {
            if existing.isHidden { setHidden(false, for: existing) }
            return .alreadyListed
        }
        settings.customFolders.append(CustomFolder(provider: provider, home: PathDisplay.abbreviate(url.path)))
        await rescan()
        if let account = accounts.first(where: { $0.id == id }) {
            await refresh([account])
        }
        return .added
    }

    func removeCustomFolder(_ account: AccountConfig) {
        settings.customFolders.removeAll { $0.accountID == account.id }
        settings.overrides[account.id] = nil
        states[account.id] = nil
        scanned.removeAll { $0.id == account.id }
        arrange()
    }

    // MARK: Order

    /// Moves `id` to the position of `target`. Accounts only move within their own provider.
    func move(_ id: String, to target: String) {
        var all = allAccounts
        guard id != target,
              let from = all.firstIndex(where: { $0.id == id }),
              let to = all.firstIndex(where: { $0.id == target }),
              all[from].provider == all[to].provider
        else { return }
        all.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        settings.order = all.map(\.id)
        arrange()
    }

    func move(_ account: AccountConfig, by offset: Int) {
        let siblings = accounts(for: account.provider)
        guard let index = siblings.firstIndex(of: account) else { return }
        let target = min(max(index + offset, 0), siblings.count - 1)
        move(account.id, to: siblings[target].id)
    }

    // MARK: Refresh

    /// Refresh on popover open when the last pass is more than a minute old.
    func refreshIfStale() {
        guard !isRefreshing, (lastRefresh.map { Date.now.timeIntervalSince($0) > 60 } ?? true) else { return }
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = .now
            cache.save(states.compactMapValues(\.usage))
        }
        // Pick up folders signed in since the last pass.
        await rescan()
        await refresh(accounts)
        // Codex reports its login only in the reading, and a failed reading can switch which of two
        // duplicate folders is shown; fetch any account that became visible.
        let fetched = Set(accounts.map(\.id))
        arrange()
        await refresh(accounts.filter { !fetched.contains($0.id) })
        arrange()
    }

    /// The last refresh pass had at least one failure, for retrying when the network comes back.
    var hasFailures: Bool {
        accounts.contains { states[$0.id]?.error?.kind == .failure }
    }

    private func refresh(_ accounts: [AccountConfig]) async {
        let context = settings.fetchContext
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.refresh(account, context: context) }
            }
        }
    }

    private func refresh(_ account: AccountConfig, context: FetchContext) async {
        guard let provider = providers[account.provider] else { return }
        states[account.id, default: AccountState()].isRefreshing = true
        let cached = states[account.id]?.usage
        do {
            let usage = try await provider.fetch(account, cached: cached, context: context)
            states[account.id] = AccountState(usage: usage)
        } catch {
            // Keep the last reading; the card shows it as stale next to the error.
            let usageError = UsageError(error)
            Log.fetch.notice("\(account.provider.title, privacy: .public) \(account.displayPath, privacy: .private): \(String(describing: usageError), privacy: .private)")
            states[account.id] = AccountState(usage: usageError.dropsReading ? nil : cached, error: usageError)
        }
    }

    /// Statusline snapshots change while Claude runs, so pick them up between full refreshes.
    func applyClaudeSnapshots() async {
        let claudeAccounts = accounts(for: .claude)
        let snapshots = await Task.detached {
            claudeAccounts.compactMap { account in ClaudeSnapshot.read(configDir: account.path).map { (account, $0) } }
        }.value
        for (account, snapshot) in snapshots {
            let current = states[account.id]?.usage
            guard snapshot.measuredAt > (current?.measuredAt ?? .distantPast) else { continue }
            var usage = snapshot.with(scoped: current?.scoped)
            if usage.plan == nil { usage.plan = current?.plan }
            if usage.plan == nil { usage.plan = await configs.config(configDir: account.path)?.planName }
            states[account.id] = AccountState(usage: usage)
        }
    }
}
