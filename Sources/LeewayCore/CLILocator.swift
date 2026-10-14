import Foundation

/// Finds a command-line tool for an app started from Finder, which does not get the shell's PATH.
public actor CLILocator {
    public static let shared = CLILocator()

    private var found: [String: String] = [:]
    private var missedAt: [String: Date] = [:]
    private var lookups: [String: Task<String?, Never>] = [:]
    /// A tool that was not found is looked up again after this time, in case the user installed it.
    private static let missRetryInterval: TimeInterval = 10 * 60

    public init() {}

    /// `first` paths, then the usual install locations (Homebrew, ~/.local/bin, npm, Bun, Volta,
    /// the newest nvm Node), then `last`, then whatever the user's login shell finds.
    public func find(_ name: String, first: [String] = [], last: [String] = []) async -> String? {
        if let path = found[name], Self.isExecutable(path) { return path }
        if let missed = missedAt[name], Date.now.timeIntervalSince(missed) < Self.missRetryInterval { return nil }
        if let running = lookups[name] { return await running.value }

        let candidates = first + Self.standardPaths(name) + last
        let lookup = Task<String?, Never> {
            if let path = candidates.first(where: Self.isExecutable) { return path }
            return await Self.loginShellPath(name)
        }
        lookups[name] = lookup
        let path = await lookup.value
        lookups[name] = nil
        found[name] = path
        missedAt[name] = path == nil ? .now : nil
        return path
    }

    /// Forgets earlier lookups, after the user installs a tool or changes a path in Settings.
    public func reset() {
        found.removeAll()
        missedAt.removeAll()
    }

    public static func isExecutable(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func standardPaths(_ name: String) -> [String] {
        let home = NSHomeDirectory()
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.bun/bin", "\(home)/.volta/bin"].map { "\($0)/\(name)" }
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        paths += versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvm)/\($0)/bin/\(name)" }
        return paths
    }

    /// `whence -p` (zsh) and `type -P` (bash) skip shell functions and aliases, which `command -v` returns.
    /// A slow shell profile cannot block the app: the shell gets 5 seconds.
    private static func loginShellPath(_ name: String) async -> String? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "whence -p \(name) 2>/dev/null || type -P \(name) 2>/dev/null || command -v \(name)"
        do {
            let result = try await Subprocess.run(shell, ["-l", "-c", script], timeout: 5)
            guard result.status == 0 else { return nil }
            let path = result.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return isExecutable(path) ? path : nil
        } catch {
            Log.discovery.notice("Login shell lookup for \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
