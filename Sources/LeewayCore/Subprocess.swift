import Foundation
import Synchronization

/// A value behind a lock, for state that callbacks on other threads change.
public final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    public init(_ value: Value) {
        mutex = Mutex(value)
    }

    public func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }

    public var value: Value { mutex.withLock { $0 } }
}

/// Runs short commands off the Swift thread pool, with a time limit.
public enum Subprocess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
    }

    public enum Failure: Error, Sendable {
        case timedOut
    }

    private static let queue = DispatchQueue(label: "Leeway.Subprocess", qos: .utility, attributes: .concurrent)

    /// Runs `path` to completion and returns its exit status and stdout. After `timeout` seconds it stops
    /// the command (SIGTERM, then SIGKILL) and throws `Failure.timedOut`.
    public static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval = 10) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Swift.Result {
                    try runBlocking(path, arguments, environment: environment, timeout: timeout)
                })
            }
        }
    }

    private static func runBlocking(_ path: String, _ arguments: [String], environment: [String: String]?,
                                    timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Read on another thread, so a full pipe never blocks the command.
        let data = Locked(Data())
        let drained = DispatchSemaphore(value: 0)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let read = reader.readDataToEndOfFile()
            data.withLock { $0 = read }
            drained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            terminate(process, exited: exited)
            throw Failure.timedOut
        }
        // A background child of the command can keep the pipe open; do not wait for it long.
        _ = drained.wait(timeout: .now() + 1)
        return Output(status: process.terminationStatus, stdout: String(decoding: data.value, as: UTF8.self))
    }

    /// SIGTERM, then SIGKILL when the process is still running after one second.
    static func terminate(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }
}
