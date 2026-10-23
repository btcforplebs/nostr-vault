import Foundation

/// Marketplace's Following / Global switch (Logen 2026-10-22): it opens on
/// Following, and Global, which shows sellers from anywhere on Nostr, waits
/// for the global feed warning. Pure for the tests; MarketplaceFeedService
/// applies it. Android: MarketplaceFeedService.requestScope.
enum MarketScopeGate {
    /// Where the marketplace opens.
    static let opensOnGlobal = false

    enum Action: Equatable {
        /// Already there: nothing to do.
        case none
        /// Switch now.
        case switchScope
        /// Ask first: the global warning, then switch on Proceed.
        case warn
    }

    /// What a request to show Global (`toGlobal`) or Following does, from where the feed is now.
    static func request(toGlobal: Bool, currentlyGlobal: Bool) -> Action {
        if toGlobal == currentlyGlobal { return .none }
        return toGlobal ? .warn : .switchScope
    }
}
