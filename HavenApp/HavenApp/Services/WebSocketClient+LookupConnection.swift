import Foundation
import Combine

/// `WebSocketClient` as a `LookupSocketPool` socket.
extension WebSocketClient: LookupConnection {
    var frames: AnyPublisher<String, Never> { messageSubject.eraseToAnyPublisher() }

    /// A new client publishes `.disconnected` twice before `.connecting` (its
    /// starting value, then `connect()` tearing down the socket it never had);
    /// `OpenWatch` keeps those from reading as a close.
    var states: AnyPublisher<LookupSocketState, Never> {
        var watch = ProfileLookupBatch.OpenWatch()
        return $connectionState
            .compactMap { state -> LookupSocketState? in
                if watch.isClosed(state.lookupState) { return .failed }
                switch state {
                case .connecting: return .connecting
                case .connected: return .connected
                case .disconnected, .error: return nil
                }
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func open(_ url: URL) {
        isTemporary = true
        connect(url: url)
    }

    func send(_ text: String) { send(text: text) }

    func close() { disconnect() }
}

extension LookupSocketPool {
    /// The app's pool: profiles, replaceable lists, zap history and the
    /// dashboard, and live rings share one socket per relay through it.
    static let shared = LookupSocketPool(makeConnection: { WebSocketClient() })
}

private extension WebSocketClient.ConnectionState {
    var lookupState: ProfileLookupBatch.SocketState {
        switch self {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .error: return .error
        }
    }
}
