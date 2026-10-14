import Foundation
import LeewayCore

extension UsageError {
    /// The text the card shows.
    var message: String {
        switch self {
        case let .notSignedIn(.claude, command):
            String(localized: "Not signed in. Run \(command), then /login.")
        case let .notSignedIn(.codex, command):
            String(localized: "Not signed in. Run \(command).")
        case .apiKeyLogin:
            String(localized: "Signed in with an API key. API keys have no plan limits.")
        case .incompleteClaudeLogin:
            String(localized: "Claude login is incomplete. Sign in again with /login.")
        case .signInExpired:
            String(localized: "Sign-in expired. Showing the last reading until you use this account in Claude Code.")
        case let .renewalFailed(command):
            String(localized: "Could not renew the sign-in. Run \(command) to sign in again.")
        case .rateLimited:
            String(localized: "Usage API is busy. Retrying later.")
        case .signInRejected:
            String(localized: "Claude rejected the sign-in. Use Claude Code with this account once to renew it.")
        case let .httpStatus(status):
            String(localized: "Claude usage API returned HTTP \(status).")
        case .unexpectedResponse:
            String(localized: "Claude usage API returned an unexpected response.")
        case let .system(text):
            text
        case .keychainTimedOut:
            String(localized: "The Keychain did not answer. Unlock it, then refresh.")
        case .codexNotFound:
            String(localized: "Codex CLI not found. Choose it in Settings.")
        case .codexNoRateLimits:
            String(localized: "Codex returned no rate limits.")
        case let .codexError(text):
            text
        case .codexTimedOut:
            String(localized: "Codex took too long to answer.")
        case .codexStopped:
            String(localized: "Codex app-server stopped. Is this account signed in?")
        }
    }

    var symbol: String {
        kind == .failure ? "exclamationmark.circle" : "info.circle"
    }
}
