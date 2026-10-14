import AppKit
import LeewayCore
import SwiftUI

/// `Leeway --dump` fetches every account once and prints the readings (never tokens).
@MainActor
enum Diagnostics {
    static func dump() async {
        let settings = AppSettings()
        let configs = ClaudeConfigStore()
        let scanned = await AccountRepository(configs: configs).scan(customFolders: settings.customFolders)
        let accounts = AccountArrangement.arrange(scanned, overrides: settings.overrides, order: settings.order, cached: [:])
        let providers: [Provider: any UsageProvider] = [.claude: ClaudeUsageProvider.live(configs: configs), .codex: CodexUsageProvider()]
        for account in accounts {
            let label = "\(account.provider.title) \(account.name) (\(account.displayPath))"
            if let duplicate = account.duplicateOf {
                print("\(label): same login as \(duplicate), hidden in the app")
            }
            if account.isHidden {
                print("\(label): hidden in Settings")
                continue
            }
            do {
                let usage = try await providers[account.provider]!.fetch(account, cached: nil, context: settings.fetchContext)
                let scoped = (usage.scoped ?? []).map { " \($0.name)=\(describe($0.window))" }.joined()
                print("\(label): plan=\(usage.plan ?? "?") email=\(usage.email ?? account.email ?? "?") session=\(describe(usage.session)) weekly=\(describe(usage.weekly))\(scoped) measured=\(UsageFormat.age(since: usage.measuredAt))")
            } catch {
                print("\(label): error: \(UsageError(error).message)")
            }
        }
    }

    private static func describe(_ window: UsageWindow?) -> String {
        guard let window else { return "none" }
        let reset = window.resetsAt.map { "resets in " + UsageFormat.duration(from: .now, to: $0) } ?? "no reset time"
        return "\(Int(window.usedPercent.rounded()))% (\(reset))"
    }

    /// `Leeway --render <dir>` writes the popover and menu bar label as PNGs:
    /// light theme showing % used, dark theme showing % left.
    /// With `--demo` it draws made-up accounts (`DemoData`) instead of the real ones, for the README.
    static func render(to dir: URL, demo: Bool = false) async {
        let settings = demo ? DemoData.settings() : AppSettings()
        let store = demo ? DemoData.store(settings: settings) : UsageStore.live(settings: settings)
        defer { if demo { DemoData.cleanUp() } }
        let updater = Updater()
        let launchAtLogin = LaunchAtLogin()
        await store.refreshAll()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previousMetric = settings.metric
        defer { settings.metric = previousMetric }
        for (name, scheme, metric) in [("light", ColorScheme.light, UsageMetric.used), ("dark", ColorScheme.dark, UsageMetric.left)] {
            settings.metric = metric
            NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let popover = PopoverView()
                .environment(store)
                .environment(settings)
                .environment(updater)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.94))
                .environment(\.colorScheme, scheme)
                .environment(\.staticRender, true)
            write(popover, to: dir.appendingPathComponent("popover-\(name).png"))
            let label = MenuBarLabel(items: store.menuBarItems(), metric: metric)
                .padding(6)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.94))
                .environment(\.colorScheme, scheme)
            write(label, to: dir.appendingPathComponent("menubar-\(name).png"))
        }
        if demo {
            settings.metric = .used
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                write(DemoHero(store: store, settings: settings, updater: updater, scheme: scheme),
                      to: dir.appendingPathComponent("hero-\(name).png"))
            }
        }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = SettingsView()
                .environment(store)
                .environment(settings)
                .environment(launchAtLogin)
                .environment(\.staticRender, true)
            // The demo waits for the CLI lookups, so the picture has paths instead of spinners.
            writeHosted(view, appearance: appearance, settle: demo ? 4 : 0.5,
                        to: dir.appendingPathComponent("settings-\(name).png"))
        }
        print("Rendered to \(dir.path)")
    }

    /// Draws through a real window, for AppKit-backed views (Form, Toggle) that ImageRenderer cannot draw.
    private static func writeHosted(_ view: some View, appearance: NSAppearance.Name, settle: TimeInterval, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(settle))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
