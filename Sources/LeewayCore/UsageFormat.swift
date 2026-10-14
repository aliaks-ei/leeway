import Foundation

/// Short texts for the cards and the menu bar, made with the system formatters so they follow the locale.
public enum UsageFormat {
    private static let units: Set<Duration.UnitsFormatStyle.Unit> = [.days, .hours, .minutes]

    /// "now", "3m ago", "2h ago", "4d ago".
    public static func age(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        let age = Duration.seconds(seconds).formatted(
            .units(allowed: units, width: .narrow, maximumUnitCount: 1, fractionalPart: .hide(rounded: .down)))
        return String(localized: "\(age) ago")
    }

    /// "5m", "2h 10m", "1d 2h": the time left until `date`, at least one minute.
    public static func duration(from now: Date, to date: Date) -> String {
        let seconds = max(60, date.timeIntervalSince(now))
        return Duration.seconds(seconds).formatted(
            .units(allowed: units, width: .narrow, maximumUnitCount: 2, zeroValueUnits: .hide,
                   fractionalPart: .hide(rounded: .down)))
    }

    /// The same, spelled out for VoiceOver: "2 hours, 10 minutes".
    public static func spokenDuration(from now: Date, to date: Date) -> String {
        let seconds = max(60, date.timeIntervalSince(now))
        return Duration.seconds(seconds).formatted(
            .units(allowed: units, width: .wide, maximumUnitCount: 2, zeroValueUnits: .hide,
                   fractionalPart: .hide(rounded: .down)))
    }

    /// 64.4 → "64%".
    public static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
