import Combine
import Network
import XCTest
@testable import MediaLogic

/// Sweep 2026-11-01 (Tara #7): an idle iPhone logged ~1,000 "Closed with code
/// 1001" in 15 minutes. 1001 is the echo of our own `cancel(with: .goingAway)`.
/// When `connect` replaced a socket, the old socket's close arrived after the
/// new one opened and marked the NEW socket `.disconnected`, so every owner
/// that reconnects on `.disconnected` closed it again: a loop.
///
/// The server here answers a close frame only after `closeReplyDelay`, so the
/// replaced socket's close always lands after its successor is connected.
final class WebSocketClientStaleCloseTests: XCTestCase {
    private var server: SlowCloseServer!
    private var bag = Set<AnyCancellable>()

    override func setUpWithError() throws {
        server = try SlowCloseServer(closeReplyDelay: 0.4)
    }

    override func tearDown() {
        bag.removeAll()
        server.stop()
    }

    private func record(_ client: WebSocketClient) -> () -> [WebSocketClient.ConnectionState] {
        var states: [WebSocketClient.ConnectionState] = []
        let lock = NSLock()
        client.$connectionState.sink { s in lock.lock(); states.append(s); lock.unlock() }.store(in: &bag)
        return { lock.lock(); defer { lock.unlock() }; return states }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testReplacedSocketsCloseDoesNotDisconnectItsSuccessor() throws {
        for delay in [0.0, 0.05, 0.4] {
            server.stop()
            server = try SlowCloseServer(closeReplyDelay: delay)
            let client = WebSocketClient()
            let states = record(client)
            client.connect(url: server.url)
            waitFor("first open") { client.connectionState == .connected }
            let mark = states().count
            client.connect(url: server.url) // replaces the socket, as every reconnect path does
            waitFor("second open") { server.accepted == 2 && client.connectionState == .connected }
            // Long enough for the first socket's close and its fallout to land.
            RunLoop.main.run(until: Date().addingTimeInterval(delay + 0.6))

            // Expected after the replace: .disconnected (the replace itself),
            // .connecting, .connected, then nothing.
            let after = Array(states().dropFirst(mark))
            let fromConnecting = after.drop { $0 != .connecting }
            XCTAssertEqual(Array(fromConnecting), [.connecting, .connected],
                           "close reply after \(delay)s: the replaced socket's end reached the live one: \(after)")
            XCTAssertEqual(client.connectionState, .connected)
            client.disconnect()
            bag.removeAll()
        }
    }

    func testDisconnectThenConnectStaysConnected() throws {
        let client = WebSocketClient()
        let states = record(client)
        client.connect(url: server.url)
        waitFor("open") { client.connectionState == .connected }
        client.disconnect()
        client.connect(url: server.url)
        waitFor("reopen") { server.accepted == 2 && client.connectionState == .connected }
        let mark = states().count
        waitFor("old close delivered", timeout: 3) { server.closesAnswered >= 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(Array(states().dropFirst(mark)).filter { $0 != .connected }, [])
        client.disconnect()
    }

    /// The complement: a close the relay starts on the live socket must
    /// still be reported, or owners would never reconnect.
    func testServerClosingTheLiveSocketIsStillReported() throws {
        let client = WebSocketClient()
        client.connect(url: server.url)
        waitFor("open") { client.connectionState == .connected }
        server.closeAll()
        waitFor("disconnect reported") {
            client.connectionState == .disconnected || client.connectionState == .error
        }
        client.disconnect()
    }
}

/// A ws:// server on 127.0.0.1 that holds back its reply to a client's close.
final class SlowCloseServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SlowCloseServer")
    private let delay: TimeInterval
    private var conns: [NWConnection] = []
    private let lock = NSLock()
    private var _accepted = 0, _closesAnswered = 0
    var accepted: Int { lock.lock(); defer { lock.unlock() }; return _accepted }
    var closesAnswered: Int { lock.lock(); defer { lock.unlock() }; return _closesAnswered }
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)")! }

    init(closeReplyDelay: TimeInterval) throws {
        delay = closeReplyDelay
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw XCTSkip("listener did not start") }
    }

    private func accept(_ c: NWConnection) {
        lock.lock(); _accepted += 1; conns.append(c); lock.unlock()
        c.start(queue: queue)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] _, ctx, _, error in
            guard let self, error == nil else { return }
            if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                self.queue.asyncAfter(deadline: .now() + self.delay) {
                    let reply = NWProtocolWebSocket.Metadata(opcode: .close)
                    reply.closeCode = .protocolCode(.goingAway)
                    let ctx = NWConnection.ContentContext(identifier: "close", metadata: [reply])
                    c.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in
                        self.lock.lock(); self._closesAnswered += 1; self.lock.unlock()
                        c.cancel()
                    })
                }
                return
            }
            self.receive(on: c)
        }
    }

    /// Closes every open connection from the server side.
    func closeAll() {
        lock.lock(); let all = conns; lock.unlock()
        for c in all {
            let m = NWProtocolWebSocket.Metadata(opcode: .close)
            m.closeCode = .protocolCode(.goingAway)
            c.send(content: nil, contentContext: .init(identifier: "close", metadata: [m]), isComplete: true,
                   completion: .contentProcessed { _ in c.cancel() })
        }
    }

    func stop() { listener.cancel(); lock.lock(); conns.forEach { $0.cancel() }; lock.unlock() }
}
