import LeewayCore
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        // A write to a CLI that has exited must fail with EPIPE instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--dump") {
            Task {
                await Diagnostics.dump()
                exit(0)
            }
            dispatchMain()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            NSApplication.shared.setActivationPolicy(.accessory)
            Task { @MainActor in
                await Diagnostics.render(to: dir)
                exit(0)
            }
            NSApplication.shared.run()
        }
        AppSettings.migrateLegacyDefaults()
        LeewayApp.main()
    }
}

/// The objects that live as long as the app.
@MainActor
final class AppModel {
    let settings: AppSettings
    let store: UsageStore
    let scheduler: RefreshScheduler
    let updater: Updater
    let launchAtLogin: LaunchAtLogin

    init() {
        settings = AppSettings()
        store = UsageStore.live(settings: settings)
        scheduler = RefreshScheduler(store: store, settings: settings)
        updater = Updater()
        launchAtLogin = LaunchAtLogin()
        scheduler.start()
    }
}

struct LeewayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model.store)
                .environment(model.settings)
                .environment(model.updater)
        } label: {
            MenuBarLabel(items: model.store.menuBarItems(), metric: model.settings.metric)
        }
        .menuBarExtraStyle(.window)

        Window("Leeway Settings", id: SettingsWindow.id) {
            SettingsView()
                .environment(model.store)
                .environment(model.settings)
                .environment(model.launchAtLogin)
        }
        // Fixed width, resizable height (the content sets both limits).
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { SettingsCommands() }
    }
}
