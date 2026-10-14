import Foundation

/// Reads the plan usage of one account.
public protocol UsageProvider: Sendable {
    /// `cached` is the last reading, which a provider may return again when it must not call its source yet.
    func fetch(_ account: AccountConfig, cached: AccountUsage?, context: FetchContext) async throws -> AccountUsage
}
