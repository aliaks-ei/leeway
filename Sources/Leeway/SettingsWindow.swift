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
        NSApp.activate()
        DispatchQueue.main.async {
            NSApp.windows
                .first { $0.identifier?.rawValue.hasPrefix(id) == true }?
                .makeKeyAndOrderFront(nil)
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
