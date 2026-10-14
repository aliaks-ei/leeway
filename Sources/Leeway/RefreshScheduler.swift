import AppKit
import LeewayCore
import Network

/// Decides when the store refreshes:
/// - every `refreshMinutes`, checked every 30 seconds, so a new interval applies at once;
/// - a few seconds after the Mac wakes;
/// - when the network comes back after a failed pass;
/// - never while the screen is locked (statusline snapshots still apply).
@MainActor
final class RefreshScheduler {
    private let store: UsageStore
    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    private var wakeRefresh: Task<Void, Never>?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private let pathMonitor = NWPathMonitor()
    private var isScreenLocked = false
    private var isNetworkAvailable = true

    private static let tick: Duration = .seconds(30)
    private static let wakeDelay: Duration = .seconds(5)

    init(store: UsageStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.store.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self else { return }
                await self.tick()
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification) { $0.refreshAfterWake() }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isScreenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { scheduler in
            scheduler.isScreenLocked = false
            scheduler.refreshIfDue()
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available: available) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Leeway.NetworkMonitor"))
    }

    func stop() {
        loop?.cancel()
        loop = nil
        wakeRefresh?.cancel()
        pathMonitor.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (RefreshScheduler) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, observer))
    }

    private var canRefresh: Bool { !isScreenLocked && isNetworkAvailable }

    private func tick() async {
        await store.applyClaudeSnapshots()
        refreshIfDue()
    }

    private func refreshIfDue() {
        guard canRefresh, !store.isRefreshing else { return }
        let interval = TimeInterval(settings.refreshMinutes * 60)
        guard store.lastRefresh.map({ Date.now.timeIntervalSince($0) >= interval }) ?? true else { return }
        Task { await store.refreshAll() }
    }

    /// The network is often not ready right after a wake, so wait a few seconds.
    private func refreshAfterWake() {
        wakeRefresh?.cancel()
        wakeRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.wakeDelay)
            guard let self, !Task.isCancelled, self.canRefresh else { return }
            Log.app.info("Refreshing after wake")
            await self.store.refreshAll()
        }
    }

    private func networkChanged(available: Bool) {
        let cameBack = available && !isNetworkAvailable
        isNetworkAvailable = available
        if cameBack, store.hasFailures, canRefresh {
            Log.app.info("Network is back; refreshing")
            Task { await store.refreshAll() }
        }
    }
}
