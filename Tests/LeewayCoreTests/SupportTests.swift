import Foundation
@testable import LeewayCore
import Testing

struct SubprocessTests {
    @Test func returnsStatusAndOutput() async throws {
        let result = try await Subprocess.run("/bin/sh", ["-c", "echo hello; exit 3"])
        #expect(result.status == 3)
        #expect(result.stdout == "hello\n")
    }

    @Test func stopsACommandThatHangs() async throws {
        let start = Date.now
        await #expect(throws: Subprocess.Failure.self) {
            try await Subprocess.run("/bin/sleep", ["30"], timeout: 0.3)
        }
        #expect(Date.now.timeIntervalSince(start) < 5)
    }

    @Test func readsLargeOutput() async throws {
        let result = try await Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a"])
        #expect(result.stdout.count == 300_000)
    }
}

struct UsageFormatTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func formatsDurations() {
        #expect(UsageFormat.duration(from: now, to: now.addingTimeInterval(2 * 3600 + 10 * 60 + 59)) == "2h 10m")
        #expect(UsageFormat.duration(from: now, to: now.addingTimeInterval(26 * 3600 + 600)) == "1d 2h")
        #expect(UsageFormat.duration(from: now, to: now.addingTimeInterval(5)) == "1m")
        #expect(UsageFormat.duration(from: now, to: now.addingTimeInterval(-100)) == "1m")
    }

    @Test func formatsAges() {
        #expect(UsageFormat.age(since: now.addingTimeInterval(-30), now: now) == "now")
        #expect(UsageFormat.age(since: now.addingTimeInterval(-180), now: now) == "3m ago")
        #expect(UsageFormat.age(since: now.addingTimeInterval(-110 * 60), now: now) == "1h ago")
        #expect(UsageFormat.age(since: now.addingTimeInterval(-3 * 86400), now: now) == "3d ago")
    }

    @Test func formatsPercentages() {
        #expect(UsageFormat.percent(64.4) == "64%")
        #expect(UsageFormat.percent(0) == "0%")
        #expect(UsageFormat.percent(100) == "100%")
    }
}

@MainActor
struct AppSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "LeewayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func savesAndLoadsEveryChoice() {
        let store = defaults()
        let settings = AppSettings(defaults: store)
        #expect(settings.refreshMinutes == 5)
        #expect(settings.renewClaudeSignIns)
        #expect(settings.metric == .used)

        settings.metric = .left
        settings.menuBarMode = .chosen
        settings.refreshMinutes = 15
        settings.renewClaudeSignIns = false
        settings.codexPath = "~/bin/codex"
        settings.order = ["b", "a"]
        settings.customFolders = [CustomFolder(provider: .codex, home: "~/x")]
        settings.updateOverride(for: "a") { $0.name = "Job" }

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.metric == .left)
        #expect(reloaded.menuBarMode == .chosen)
        #expect(reloaded.refreshMinutes == 15)
        #expect(!reloaded.renewClaudeSignIns)
        #expect(reloaded.resolvedCodexPath == NSHomeDirectory() + "/bin/codex")
        #expect(reloaded.order == ["b", "a"])
        #expect(reloaded.customFolders.first?.path == NSHomeDirectory() + "/x")
        #expect(reloaded.override(for: "a").name == "Job")
    }

    @Test func dropsOverridesWithOnlyDefaults() {
        let settings = AppSettings(defaults: defaults())
        settings.updateOverride(for: "a") { $0.hidden = true }
        settings.updateOverride(for: "a") { $0.hidden = false }
        #expect(settings.overrides.isEmpty)
    }

    @Test func readsKeysOfEarlierVersions() {
        let store = defaults()
        store.set("left", forKey: "usageMetric")
        store.set(10, forKey: "refreshMinutes")
        store.set(["x"], forKey: "accountOrder")
        let settings = AppSettings(defaults: store)
        #expect(settings.metric == .left)
        #expect(settings.refreshMinutes == 10)
        #expect(settings.order == ["x"])
    }
}

struct LockedTests {
    @Test func keepsConcurrentChanges() async {
        let counter = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 100 {
                group.addTask { counter.withLock { $0 += 1 } }
            }
        }
        #expect(counter.value == 100)
    }
}
