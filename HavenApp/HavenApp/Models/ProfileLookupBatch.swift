import Foundation

/// The rules for the reusable profile lookup sockets
/// (NostrService+Profiles.swift), kept pure so they can be tested.
enum ProfileLookupBatch {
    /// Authors per profile REQ. One REQ asks for 5 kinds per author, and many
    /// relays stop at about 500 events a subscription: the Hashtags feed sent
    /// 403 authors in one REQ (sweep 2026-11-01 #1). Android's topic screener
    /// uses 100 too (TopicFeedScreener.AUTHORS_PER_FILTER).
    static let authorsPerRequest = 100

    /// `pubkeys` in REQ-sized pieces, in order.
    static func chunks(_ pubkeys: [String], size: Int = authorsPerRequest) -> [[String]] {
        let size = max(1, size)
        return stride(from: 0, to: pubkeys.count, by: size).map { Array(pubkeys[$0..<min($0 + size, pubkeys.count)]) }
    }

    enum SocketState { case disconnected, connecting, connected, error }

    /// Tells a socket closing from a socket not yet opened. A new
    /// WebSocketClient publishes `.disconnected` before `.connecting`: its
    /// starting value, and `connect()` tearing down the socket it never had.
    /// Taking that for a close threw the queued batch away and dropped the
    /// socket from the map, so no lookup REQ was ever sent and feed authors
    /// stayed bare keys (sweep 2026-11-01 #1).
    struct OpenWatch {
        private(set) var started = false

        /// True when `state` means the socket is gone.
        mutating func isClosed(_ state: SocketState) -> Bool {
            switch state {
            case .connecting, .connected:
                started = true
                return false
            case .disconnected:
                return started
            case .error:
                // Refused before connecting (a blocked relay) is gone too.
                return true
            }
        }
    }
}
