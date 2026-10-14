import os

/// Unified logging. Read it with `log stream --predicate 'subsystem == "io.github.aliaks-ei.Leeway"'`.
/// Emails and paths are private; tokens are never logged.
public enum Log {
    public static let subsystem = AppInfo.bundleIdentifier

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let fetch = Logger(subsystem: subsystem, category: "fetch")
    public static let renewal = Logger(subsystem: subsystem, category: "renewal")
}
