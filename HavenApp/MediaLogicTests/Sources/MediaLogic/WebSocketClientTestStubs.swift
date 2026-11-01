import Foundation

// Stand-ins for the two app types WebSocketClient.swift names outside the
// client itself (LocalTLSTrust's pin warning and MediaSessionService's FIPS
// guard). WebSocketClientStaleCloseTests uses plain ws:// on loopback, so
// neither is reached.

extension RelayProcessManager {
    func addLog(_ message: String, level: String = "INFO") {}
}

final class FipsHostBlocker: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
