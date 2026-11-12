import AppKit
import SwiftUI

/// The Settings window. A custom `Window` scene, because `SettingsLink` does not bring a menu bar app
/// to the front reliably.
///
/// While the window is open the app is a regular app: it has a Dock icon and shows in ⌘-Tab and
/// Mission Control, as users expect of a window. It goes back to a menu bar app when the window closes.
@MainActor
enum SettingsWindow {
    static let id = "settings"

    static func show(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        // The scene shows its window, and the policy change takes effect, some run loop turns later.
        // Before that, activation does nothing and the window stays behind the other apps. So wait for it.
        Task {
            for _ in 0 ..< 40 {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }),
                   window.isVisible {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    // In front even when macOS does not make the app active.
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    static func didClose() {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// ⌘, in the app menu, which exists while the Settings window makes the app a regular app.
struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindow.show(openWindow) }
                .keyboardShortcut(",")
        }
    }
}
