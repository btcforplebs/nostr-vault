import Network
import XCTest
@testable import MediaLogic

/// Relay connections name the app: "NostrVault/<version> (iOS|macOS)", read
/// off the wire from the upgrade request a real WebSocketClient sends.
final class RelayUserAgentTests: XCTestCase {
    func testUpgradeRequestCarriesNostrVaultUserAgent() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "RelayUserAgentTests")
        let ready = DispatchSemaphore(value: 0)
        let got = expectation(description: "upgrade request")
        var request = ""
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                request = String(decoding: data ?? Data(), as: UTF8.self)
                c.cancel()
                got.fulfill()
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        guard ready.wait(timeout: .now() + 5) == .success else { throw XCTSkip("listener did not start") }

        let client = WebSocketClient()
        client.connect(url: URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)")!)
        wait(for: [got], timeout: 5)
        client.disconnect()

        let ua = request.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("user-agent:") }
            .map { $0.dropFirst("user-agent:".count).trimmingCharacters(in: .whitespaces) }
        print("Apple User-Agent: \(ua ?? "<none>")")
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        XCTAssertEqual(ua, RelayUserAgent.value)
        XCTAssertTrue(ua?.hasPrefix("NostrVault/") == true && ua?.hasSuffix(" (\(platform))") == true, ua ?? "nil")
    }
}
