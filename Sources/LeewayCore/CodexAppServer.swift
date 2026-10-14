import Foundation

/// One short-lived `codex app-server` process speaking newline-delimited JSON-RPC over stdio.
enum CodexAppServer {
    struct Call: Sendable {
        var method: String
        /// Nil sends no `params` key; `[:]` sends an empty object.
        var params: [String: String]?
    }

    /// Sends `initialize`, then each call, and returns each call's `result` object as JSON data, in order.
    static func request(binary: String, home: String, calls: [Call], timeout: TimeInterval) async throws -> [Data] {
        // A write to a CLI that has already exited must fail with EPIPE instead of killing the app.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: home)

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let ids = calls.indices.map { $0 + 2 }
        let session = Session(ids: ids)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil // EOF: the CLI has exited.
                session.finish(.failure(.codexStopped))
            } else {
                session.consume(data)
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        try process.run()

        do {
            for message in messages(calls) {
                var line = try JSONSerialization.data(withJSONObject: message)
                line.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: line)
            }
        } catch {
            throw UsageError.codexStopped
        }
        return try await session.wait(timeout: timeout)
    }

    private static func messages(_ calls: [Call]) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "leeway", "version": AppInfo.version]]],
            ["method": "initialized"],
        ]
        for (offset, call) in calls.enumerated() {
            var message: [String: Any] = ["id": offset + 2, "method": call.method]
            if let params = call.params { message["params"] = params }
            messages.append(message)
        }
        return messages
    }

    /// Collects the answers from the reader thread and hands them to the waiting task once.
    final class Session: Sendable {
        private struct State {
            var buffer = Data()
            var results: [Int: Data] = [:]
            var outcome: Result<[Data], UsageError>?
            var continuation: CheckedContinuation<[Data], any Error>?
        }

        private let ids: [Int]
        private let state = Locked(State())

        init(ids: [Int]) {
            self.ids = ids
        }

        func wait(timeout: TimeInterval) async throws -> [Data] {
            let timer = Task { [weak self] in
                try await Task.sleep(for: .seconds(timeout))
                self?.finish(.failure(.codexTimedOut))
            }
            defer { timer.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                let outcome = state.withLock { state -> Result<[Data], UsageError>? in
                    if state.outcome == nil { state.continuation = continuation }
                    return state.outcome
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        }

        /// The first outcome wins; later ones (EOF after the answers, a late timeout) are ignored.
        func finish(_ outcome: Result<[Data], UsageError>) {
            let continuation = state.withLock { state -> CheckedContinuation<[Data], any Error>? in
                guard state.outcome == nil else { return nil }
                state.outcome = outcome
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: outcome)
        }

        func consume(_ data: Data) {
            let outcome = state.withLock { state -> Result<[Data], UsageError>? in
                state.buffer.append(data)
                while let newline = state.buffer.firstIndex(of: 0x0A) {
                    let line = state.buffer[state.buffer.startIndex ..< newline]
                    state.buffer.removeSubrange(state.buffer.startIndex ... newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = message["id"] as? Int
                    else { continue }
                    if let result = message["result"] as? [String: Any],
                       let json = try? JSONSerialization.data(withJSONObject: result) {
                        state.results[id] = json
                    } else if let error = message["error"] as? [String: Any], ids.contains(id) {
                        return .failure(.codexError((error["message"] as? String) ?? "Codex returned an error."))
                    }
                }
                guard ids.allSatisfy({ state.results[$0] != nil }) else { return nil }
                return .success(ids.compactMap { state.results[$0] })
            }
            if let outcome { finish(outcome) }
        }
    }
}
