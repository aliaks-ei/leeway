import Foundation
import LeewayCore

/// Made-up accounts and readings for `Leeway --render <dir> --demo`, which draws the README screenshots.
/// Nothing is read from or written to the real accounts, settings or cache.
@MainActor
enum DemoData {
    private static let suite = "io.github.aliaks-ei.Leeway.demo"

    private struct Fixture {
        var provider: Provider
        var folder: String
        var email: String
        var usage: @Sendable (Date) -> AccountUsage
    }

    private static let fixtures: [Fixture] = [
        Fixture(provider: .claude, folder: ".claude", email: "alex@example.com") { now in
            AccountUsage(session: window(42, resetsIn: hours(2.2), now), weekly: window(61, resetsIn: days(3.4), now),
                         plan: "Max 5x", measuredAt: now.addingTimeInterval(-40), email: "alex@example.com",
                         scoped: [ScopedWindow(name: "Fable", window: window(38, resetsIn: days(3.4), now))])
        },
        Fixture(provider: .claude, folder: ".claude-work", email: "alex@acme.example") { now in
            AccountUsage(session: window(87, resetsIn: hours(0.6), now), weekly: window(54, resetsIn: days(5.1), now),
                         plan: "Max 20x", measuredAt: now.addingTimeInterval(-40), email: "alex@acme.example")
        },
        Fixture(provider: .codex, folder: ".codex", email: "alex@example.com") { now in
            AccountUsage(session: window(18, resetsIn: hours(3.7), now), weekly: window(33, resetsIn: days(4.2), now),
                         plan: "Plus", measuredAt: now.addingTimeInterval(-40), email: "alex@example.com")
        },
        Fixture(provider: .codex, folder: ".codex-work", email: "alex@acme.example") { now in
            AccountUsage(session: window(64, resetsIn: hours(1.4), now), weekly: window(72, resetsIn: days(1.8), now),
                         plan: "Business", measuredAt: now.addingTimeInterval(-40), email: "alex@acme.example")
        },
    ]

    /// Settings in their own defaults domain, cleared first, with "Personal" for the default folders.
    static func settings() -> AppSettings {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        for provider in Provider.allCases {
            let id = AccountConfig.id(provider: provider, path: path(provider.defaultFolder))
            settings.updateOverride(for: id) { $0.name = "Personal" }
        }
        return settings
    }

    static func store(settings: AppSettings) -> UsageStore {
        let accounts = fixtures.map { fixture in
            AccountConfig(provider: fixture.provider, path: path(fixture.folder),
                          isDefaultFolder: fixture.folder == fixture.provider.defaultFolder,
                          email: fixture.email, identity: "\(fixture.provider.rawValue):\(fixture.email)")
        }
        let usages = Dictionary(uniqueKeysWithValues: fixtures.map { (path($0.folder), $0.usage) })
        let provider = DemoProvider(usages: usages)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("leeway-demo-cache.json")
        try? FileManager.default.removeItem(at: cache)
        return UsageStore(settings: settings, scan: { _ in accounts }, providers: [.claude: provider, .codex: provider],
                          configs: ClaudeConfigStore(), cache: UsageCache(file: cache))
    }

    static func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private struct DemoProvider: UsageProvider {
        let usages: [String: @Sendable (Date) -> AccountUsage]

        func fetch(_ account: AccountConfig, cached: AccountUsage?, context: FetchContext) async throws -> AccountUsage {
            usages[account.path]!(.now)
        }
    }

    nonisolated private static func path(_ folder: String) -> String { NSHomeDirectory() + "/" + folder }
    nonisolated private static func hours(_ value: Double) -> TimeInterval { value * 3600 }
    nonisolated private static func days(_ value: Double) -> TimeInterval { value * 86400 }

    nonisolated private static func window(_ used: Double, resetsIn interval: TimeInterval, _ now: Date) -> UsageWindow {
        UsageWindow(usedPercent: used, resetsAt: now.addingTimeInterval(interval))
    }
}

import SwiftUI

/// The README's first image: a menu bar with the label, and the popover open under it.
struct DemoHero: View {
    let store: UsageStore
    let settings: AppSettings
    let updater: Updater
    let scheme: ColorScheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            menuBar
            HStack {
                Spacer()
                PopoverView()
                    .environment(store)
                    .environment(settings)
                    .environment(updater)
                    .background(dark ? Color(white: 0.17) : Color(white: 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(dark ? 0.18 : 0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 24, y: 10)
                    .padding(.trailing, 170)
            }
            .padding(.top, 6)
            .padding(.bottom, 56)
        }
        .frame(width: 760)
        .background(LinearGradient(
            colors: dark ? [Color(red: 0.13, green: 0.15, blue: 0.27), Color(red: 0.30, green: 0.16, blue: 0.24)]
                         : [Color(red: 0.62, green: 0.74, blue: 0.95), Color(red: 0.96, green: 0.76, blue: 0.70)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, scheme)
        .environment(\.staticRender, true)
    }

    private var menuBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            Text("File")
            Text("Edit")
            Text("View")
            Spacer()
            MenuBarLabel(items: store.menuBarItems(), metric: settings.metric)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Tue 14 Oct  9:41")
        }
        .font(.system(size: 13))
        .foregroundStyle(dark ? .white : .black)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
    }
}
