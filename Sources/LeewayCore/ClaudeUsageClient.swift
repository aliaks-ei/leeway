import Foundation

/// Reads Claude plan usage with an access token. Tests use a fake.
public protocol ClaudeUsageClient: Sendable {
    func usage(token: String) async throws -> AccountUsage
}

public enum ClaudeAPIError: Error, Equatable, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
}

/// `GET api.anthropic.com/api/oauth/usage`. The endpoint is undocumented and can change.
public struct ClaudeHTTPUsageClient: ClaudeUsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    /// An ephemeral session keeps no responses, cookies or credentials on disk.
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func usage(token: String) async throws -> AccountUsage {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Say who is asking; the app does not pretend to be Claude Code.
        request.setValue("Leeway/\(AppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.system(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 429: throw ClaudeAPIError.rateLimited(retryAfter: Self.retryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        case 401, 403: throw UsageError.signInRejected
        case let status: throw UsageError.httpStatus(status)
        }
        return try Self.parse(data)
    }

    /// `Retry-After` as seconds or as an HTTP date.
    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Reads the `limits` array when present, otherwise the older `five_hour` / `seven_day` objects.
    /// A `weekly_scoped` row with a model scope is a per-model weekly window, such as Fable.
    public static func parse(_ data: Data, now: Date = .now) throws -> AccountUsage {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw UsageError.unexpectedResponse
        }
        var session: UsageWindow?
        var weekly: UsageWindow?
        var scoped: [ScopedWindow]?
        if let limits = response.limits {
            var models: [ScopedWindow] = []
            for limit in limits {
                guard let percent = limit.percent else { continue }
                let window = UsageWindow(usedPercent: percent, resetsAt: limit.resetsAt)
                switch limit.kind {
                case "session": session = session ?? window
                case "weekly_all": weekly = weekly ?? window
                case "weekly_scoped":
                    guard let name = limit.modelName, !name.isEmpty, !models.contains(where: { $0.name == name }) else { continue }
                    models.append(ScopedWindow(name: name, window: window))
                default: break
                }
            }
            scoped = models
        }
        return AccountUsage(
            session: session ?? response.fiveHour?.window,
            weekly: weekly ?? response.sevenDay?.window,
            measuredAt: now,
            scoped: scoped)
    }

    private struct Response: Decodable {
        struct Limit: Decodable {
            var kind: String?
            var percent: Double?
            var resetsAt: Date?
            var modelName: String?

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
                kind = container.string(.kind)
                percent = container.number(.percent)
                resetsAt = container.date(.resetsAt)
                let model = container.nested(ScopeKeys.self, .scope)?.nested(ModelKeys.self, .model)
                modelName = model?.string(.displayName)
            }

            private enum CodingKeys: String, CodingKey {
                case kind, percent, scope
                case resetsAt = "resets_at"
            }

            private enum ScopeKeys: String, CodingKey { case model }
            private enum ModelKeys: String, CodingKey { case displayName = "display_name" }
        }

        struct LegacyWindow: Decodable {
            var window: UsageWindow?

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                      let used = container.number(.utilization)
                else { return }
                window = UsageWindow(usedPercent: used, resetsAt: container.date(.resetsAt))
            }

            private enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        var limits: [Limit]?
        var fiveHour: LegacyWindow?
        var sevenDay: LegacyWindow?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limits = container.lenient([Limit].self, .limits)
            fiveHour = container.lenient(LegacyWindow.self, .fiveHour)
            sevenDay = container.lenient(LegacyWindow.self, .sevenDay)
        }

        private enum CodingKeys: String, CodingKey {
            case limits
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }
}

/// The file that `scripts/claude-statusline-snapshot.sh` writes from the statusline's `rate_limits`.
public enum ClaudeSnapshot {
    public static func read(configDir: String, directory: URL = AppPaths.claudeSnapshotsDir) -> AccountUsage? {
        (try? Data(contentsOf: ClaudePaths.snapshotURL(configDir: configDir, directory: directory))).flatMap(parse)
    }

    public static func parse(_ data: Data) -> AccountUsage? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), let captured = file.capturedAt,
              file.fiveHour?.window != nil || file.sevenDay?.window != nil
        else { return nil }
        return AccountUsage(
            session: file.fiveHour?.window,
            weekly: file.sevenDay?.window,
            measuredAt: Date(timeIntervalSince1970: captured))
    }

    private struct File: Decodable {
        struct Window: Decodable {
            var window: UsageWindow?

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                      let used = container.number(.usedPercentage)
                else { return }
                window = UsageWindow(usedPercent: used, resetsAt: container.date(.resetsAt))
            }

            private enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }

        var capturedAt: Double?
        var fiveHour: Window?
        var sevenDay: Window?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            capturedAt = container.number(.capturedAt)
            fiveHour = container.lenient(Window.self, .fiveHour)
            sevenDay = container.lenient(Window.self, .sevenDay)
        }

        private enum CodingKeys: String, CodingKey {
            case capturedAt = "captured_at"
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }
}
