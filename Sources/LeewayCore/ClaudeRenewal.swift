import Darwin
import Foundation

/// Gets Claude Code to renew an expired sign-in. Tests use a fake.
public protocol ClaudeSignInRenewer: Sendable {
    /// Returns when the CLI has had its chance to renew the token. The caller reads the Keychain afterwards.
    func renew(_ account: AccountConfig) async
}

/// Renews an expired Claude Code sign-in by starting `claude` for that config folder and quitting it
/// once the token is fresh. The CLI renews its own token at startup and saves it in its own Keychain
/// item, so Leeway never handles the renewal key and cannot sign the CLI out.
///
/// `claude` runs in an empty folder that is never trusted. It stops at the folder trust prompt,
/// before any project files, hooks or MCP servers load, and it never sends a message. The auto-updater
/// and other non-essential traffic are turned off, because Leeway quits the CLI after a few seconds.
public struct ClaudeCLIRenewer: ClaudeSignInRenewer {
    private let credentials: any ClaudeCredentialSource
    private let locator: CLILocator
    private static let timeout: TimeInterval = 20
    /// After the trust prompt shows, the CLI has done its startup work; wait this long for the token.
    private static let graceAfterTrustPrompt: TimeInterval = 3

    public init(credentials: any ClaudeCredentialSource, locator: CLILocator = .shared) {
        self.credentials = credentials
        self.locator = locator
    }

    /// The `claude` program that renewal starts, for Settings.
    public static func binary(locator: CLILocator = .shared) async -> String? {
        let home = NSHomeDirectory()
        return await locator.find("claude", first: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude"])
    }

    /// The environment for the CLI: the app's own, without Claude and Anthropic settings that could point
    /// it at another account, and with the auto-updater and non-essential traffic off.
    static func environment(for account: AccountConfig, base: [String: String]) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        // The default folder must run without the variable: setting it changes the Keychain item name.
        if !account.isDefaultFolder { environment["CLAUDE_CONFIG_DIR"] = account.path }
        environment["TERM"] = "xterm-256color"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return environment
    }

    public func renew(_ account: AccountConfig) async {
        guard let binary = await Self.binary(locator: locator) else {
            Log.renewal.error("Claude CLI not found; cannot renew the sign-in")
            return
        }
        let workDir = AppPaths.claudeRenewDir
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // The CLI draws a terminal UI and exits without a terminal, so give it a pseudo-terminal.
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = workDir
        process.environment = Self.environment(for: account, base: ProcessInfo.processInfo.environment)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            close(master)
            Log.renewal.error("Could not start claude: \(error.localizedDescription, privacy: .public)")
            return
        }
        try? terminal.close()
        Log.renewal.info("Started claude to renew \(account.displayPath, privacy: .private)")

        // Read the screen, so the CLI never blocks on a full buffer and so the app can see the trust
        // prompt. The read fails once the CLI exits, and the reader closes its end then.
        let screen = Locked("")
        let masterFD = master
        DispatchQueue.global(qos: .utility).async {
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = read(masterFD, &buffer, buffer.count)
                guard count > 0 else { break }
                let text = String(decoding: buffer[0 ..< count], as: UTF8.self).lowercased()
                screen.withLock { $0 = String(($0 + text).suffix(8192)) }
            }
            close(masterFD)
        }

        await waitForFreshToken(account, process: process, screen: screen)
        await Task.detached { Subprocess.terminate(process, exited: exited) }.value
    }

    private func waitForFreshToken(_ account: AccountConfig, process: Process, screen: Locked<String>) async {
        let deadline = Date.now.addingTimeInterval(Self.timeout)
        var trustPromptAt: Date?
        while Date.now < deadline, process.isRunning {
            try? await Task.sleep(for: .milliseconds(500))
            if await isFresh(account) {
                Log.renewal.info("Sign-in renewed")
                return
            }
            if trustPromptAt == nil, screen.value.contains("trust") { trustPromptAt = .now }
            if let shown = trustPromptAt, Date.now.timeIntervalSince(shown) > Self.graceAfterTrustPrompt {
                Log.renewal.error("The CLI reached the trust prompt without a new token")
                return
            }
        }
        if trustPromptAt == nil {
            Log.renewal.error("The CLI did not show the trust prompt; stopped it")
        }
    }

    private func isFresh(_ account: AccountConfig) async -> Bool {
        guard let credentials = try? await credentials.credentials(configDir: account.path) else { return false }
        return !credentials.isExpired()
    }
}
