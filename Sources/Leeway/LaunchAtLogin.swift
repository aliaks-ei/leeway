import LeewayCore
import Observation
import ServiceManagement

/// The "Launch at login" state. The user can also change it in System Settings → General → Login Items,
/// so the Settings window reads it again each time the app becomes active.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    init() {
        refresh()
    }

    /// On, or registered and waiting for the user's approval in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func set(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
