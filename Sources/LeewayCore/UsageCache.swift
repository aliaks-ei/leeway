import Foundation

/// The last reading of each account, so a restart shows numbers at once. It holds no tokens.
public struct UsageCache: Sendable {
    private let file: URL

    public init(file: URL = AppPaths.cacheFile) {
        self.file = file
    }

    public func load() -> [String: AccountUsage] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: AccountUsage].self, from: data)) ?? [:]
    }

    public func save(_ usages: [String: AccountUsage]) {
        guard let data = try? JSONEncoder().encode(usages) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            Log.app.error("Could not save the cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
