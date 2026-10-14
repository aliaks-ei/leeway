import Foundation

/// Why an account has no new reading. The app builds the text for each case; this layer has none.
public enum UsageError: Error, Equatable, Sendable {
    /// The folder has no login. `loginCommand` signs it in.
    case notSignedIn(Provider, loginCommand: String)
    /// An API-key login, which has no plan limits.
    case apiKeyLogin
    /// The Claude login in the Keychain has no access token.
    case incompleteClaudeLogin
    /// The Claude token expired and renewal is off. The last reading still stands.
    case signInExpired
    /// The Claude token expired and the CLI did not renew it.
    case renewalFailed(loginCommand: String)
    /// The usage endpoint answered HTTP 429, or the back-off after one is still running.
    case rateLimited
    /// The usage endpoint answered HTTP 401 or 403.
    case signInRejected
    case httpStatus(Int)
    case unexpectedResponse
    /// A network or other system error, with the system's text.
    case system(String)
    /// `/usr/bin/security` did not answer in time, for example while a Keychain dialog is open.
    case keychainTimedOut
    case codexNotFound
    case codexNoRateLimits
    /// The Codex app-server returned an error, with its text.
    case codexError(String)
    case codexTimedOut
    case codexStopped

    public enum Kind: Sendable {
        /// Something failed.
        case failure
        /// An expected state that has no numbers to show.
        case info
        /// The last reading still stands, but it cannot be updated now.
        case stale
    }

    public var kind: Kind {
        switch self {
        case .apiKeyLogin: .info
        case .signInExpired: .stale
        default: .failure
        }
    }

    /// The account has no reading of its own, so an old one would mislead.
    public var dropsReading: Bool { self == .apiKeyLogin }

    public init(_ error: any Error) {
        self = (error as? UsageError) ?? .system(error.localizedDescription)
    }
}
