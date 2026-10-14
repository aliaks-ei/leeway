import Foundation
@testable import LeewayCore
import Testing

struct CodexParsingTests {
    private let account = Data("""
    {"account": {"type": "chatgpt", "email": "a@b.c", "planType": "prolite"}, "workspaceRouting": {"chatgptAccountId": "ws1"}}
    """.utf8)

    @Test func readsLimitsByIDAndSortsWindowsByLength() throws {
        // Pro Lite: only a weekly window, reported as `primary`.
        let limits = Data("""
        {"rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 30, "resetsAt": 1791900000, "windowDurationMins": 10080}},
                                 "other": 5},
         "rateLimits": {"primary": {"usedPercent": 99}}}
        """.utf8)
        let usage = try CodexUsageProvider.parse(account: account, rateLimits: limits, loginCommand: "codex login")
        #expect(usage.session == nil)
        #expect(usage.weekly == UsageWindow(usedPercent: 30, resetsAt: Date(timeIntervalSince1970: 1_791_900_000)))
        #expect(usage.plan == "Pro Lite")
        #expect(usage.email == "a@b.c")
        #expect(usage.identity == "codex:ws1:a@b.c")
    }

    @Test func fallsBackToRateLimitsAndPosition() throws {
        let limits = Data("""
        {"rateLimits": {"primary": {"usedPercent": "12"}, "secondary": {"usedPercent": 40}, "planType": "plus"}}
        """.utf8)
        let noPlan = Data(#"{"account": {"type": "chatgpt"}}"#.utf8)
        let usage = try CodexUsageProvider.parse(account: noPlan, rateLimits: limits, loginCommand: "codex login")
        #expect(usage.session?.usedPercent == 12)
        #expect(usage.weekly?.usedPercent == 40)
        #expect(usage.plan == "Plus")
        #expect(usage.identity == nil)
    }

    @Test func reportsLoginStates() {
        let limits = Data(#"{"rateLimits": {}}"#.utf8)
        #expect(throws: UsageError.notSignedIn(.codex, loginCommand: "x")) {
            try CodexUsageProvider.parse(account: Data(#"{"account": null}"#.utf8), rateLimits: limits, loginCommand: "x")
        }
        #expect(throws: UsageError.apiKeyLogin) {
            try CodexUsageProvider.parse(account: Data(#"{"account": {"type": "apiKey"}}"#.utf8), rateLimits: limits, loginCommand: "x")
        }
        #expect(throws: UsageError.codexNoRateLimits) {
            try CodexUsageProvider.parse(account: account, rateLimits: Data("{}".utf8), loginCommand: "x")
        }
    }

    @Test func namesPlans() {
        #expect(CodexUsageProvider.planName("enterprise_x") == "Enterprise")
        #expect(CodexUsageProvider.planName("self_serve_business_prolite") == "Business")
        #expect(CodexUsageProvider.planName("unknown") == nil)
        #expect(CodexUsageProvider.planName(nil) == nil)
        #expect(CodexUsageProvider.planName("free") == "Free")
    }
}

struct CodexAppServerTests {
    /// A fake `codex` that answers like the app-server, written as a shell script.
    private func fakeCodex(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func returnsResultsInOrder() async throws {
        let binary = try fakeCodex("""
        read a; read b; read c; read d
        echo '{"id":1,"result":{}}'
        echo '{"method":"note"}'
        echo '{"id":3,"result":{"n":3}}'
        echo '{"id":2,"result":{"n":2}}'
        sleep 5
        """)
        let results = try await CodexAppServer.request(binary: binary, home: NSTemporaryDirectory(), calls: [
            .init(method: "a", params: [:]), .init(method: "b", params: nil),
        ], timeout: 5)
        let numbers = try results.map { try JSONSerialization.jsonObject(with: $0) as? [String: Int] }
        #expect(numbers == [["n": 2], ["n": 3]])
    }

    @Test func reportsCallError() async throws {
        let binary = try fakeCodex("""
        read a; read b; read c
        echo '{"id":2,"error":{"message":"nope"}}'
        sleep 5
        """)
        await #expect(throws: UsageError.codexError("nope")) {
            try await CodexAppServer.request(binary: binary, home: NSTemporaryDirectory(), calls: [.init(method: "a")], timeout: 5)
        }
    }

    /// The CLI exits at once. Before the fix, the write to its closed pipe raised SIGPIPE and killed the app.
    @Test func survivesCLIThatExitsAtOnce() async throws {
        let binary = try fakeCodex("exit 0\n")
        await #expect(throws: UsageError.codexStopped) {
            try await CodexAppServer.request(binary: binary, home: NSTemporaryDirectory(), calls: [.init(method: "a")], timeout: 5)
        }
    }

    @Test func timesOut() async throws {
        let binary = try fakeCodex("sleep 10\n")
        await #expect(throws: UsageError.codexTimedOut) {
            try await CodexAppServer.request(binary: binary, home: NSTemporaryDirectory(), calls: [.init(method: "a")], timeout: 0.5)
        }
    }
}

private extension CodexAppServer.Call {
    init(method: String) { self.init(method: method, params: nil) }
}
