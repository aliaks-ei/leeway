import AppKit
import LeewayCore
import Observation
import Sparkle

/// "Check for Updates": Sparkle when the build has a feed and a public key, otherwise the releases page.
///
/// Sparkle needs `SUFeedURL` (the appcast) and `SUPublicEDKey` (from Sparkle's `generate_keys`) in
/// Info.plist. It checks the EdDSA signature of each update before it installs it.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        if Self.isConfigured {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let canCheck = change.newValue ?? false
                Task { @MainActor in self?.canCheckForUpdates = canCheck }
            }
        } else {
            controller = nil
            canCheckForUpdates = AppInfo.releasesURL != nil
        }
    }

    /// Whether the menu shows "Check for Updates…".
    var isAvailable: Bool { controller != nil || AppInfo.releasesURL != nil }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
        } else if let url = AppInfo.releasesURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static var isConfigured: Bool {
        func value(_ key: String) -> String? {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return value("SUFeedURL") != nil && value("SUPublicEDKey") != nil
    }
}
