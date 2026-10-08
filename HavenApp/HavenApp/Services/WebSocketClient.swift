import Foundation
import Combine
import CryptoKit
import Security

/// Helper to identify if a host is local or on the local network (LAN/mDNS)
func isLocalNetworkHost(_ host: String?) -> Bool {
    LocalTLSPolicy.kind(of: host) != .public
}

/// TLS for hosts a public certificate can't cover: this device's own relay
/// and relays on the local network, which use self-signed certificates.
/// Loopback is trusted as is. A LAN host with a certificate the system
/// accepts is checked normally; otherwise its certificate is pinned the first
/// time it is seen and must match after that, so another device on the same
/// Wi-Fi can't stand in for it. Everything else gets default handling.
enum LocalTLSTrust {
    private static let pinsKey = "localTLSPins"
    private static let lock = NSLock()

    static func handle(_ challenge: URLAuthenticationChallenge,
                       completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch LocalTLSPolicy.kind(of: space.host) {
        case .public:
            completionHandler(.performDefaultHandling, nil)
        case .loopback:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .lan:
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let fingerprint = leafFingerprint(trust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let key = "\(space.host.lowercased()):\(space.port)"
            lock.lock()
            var pins = UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
            let decision = LocalTLSPolicy.decide(pinned: pins[key], presented: fingerprint)
            if decision == .acceptAndPin {
                pins[key] = fingerprint
                UserDefaults.standard.set(pins, forKey: pinsKey)
            }
            lock.unlock()
            if decision == .reject {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
        }
    }

    /// SHA-256 of the server's leaf certificate, hex.
    private static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSessionDelegate that trusts this device's relay and pins LAN relays
/// (see `LocalTLSTrust`).
class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        LocalTLSTrust.handle(challenge, completionHandler: completionHandler)
    }
}

/// Centralized service for media loading with proper certificate handling for localhost
class MediaSessionService {
    static let shared = MediaSessionService()

    private let localhostDelegate: LocalhostTrustDelegate
    let session: URLSession

    private init() {
        // Configure session with timeouts suitable for media downloads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60  // 60 seconds for individual requests
        config.timeoutIntervalForResource = 600  // 10 minutes for full resource
        config.waitsForConnectivity = true

        // Create delegate that trusts self-signed certs for localhost
        self.localhostDelegate = LocalhostTrustDelegate()
        self.session = URLSession(configuration: config, delegate: localhostDelegate, delegateQueue: nil)
    }
}

class WebSocketClient: NSObject, ObservableObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum ConnectionState: String {
        case disconnected
        case connecting
        case connected
        case error
    }

    private var webSocketTask: URLSessionWebSocketTask?
    @Published var connectionState: ConnectionState = .disconnected
    private var lastError: String?
    private var isClosing = false
    var isTemporary = false
    let messageSubject = PassthroughSubject<String, Never>()

    private var url: URL?

    // Keepalive: send a WebSocket ping every 25 s so iOS doesn't kill idle connections
    // ("Operation timed out" / "Socket is not connected" in the OS log).
    private var pingTimer: DispatchSourceTimer?
    private static let pingInterval: TimeInterval = 25

    // Per-instance URLSession so that WebSocket delegate callbacks (didOpen, didClose,
    // didCompleteWithError) are delivered to THIS object, not a shared delegate.
    // Created on connect, invalidated on disconnect to break the URLSession→delegate retain cycle.
    private var session: URLSession?

    /// Serializes ALL access to the mutable connection state above
    /// (`webSocketTask`, `session`, `url`, `isClosing`, `pingTimer`, `lastError`).
    /// These properties are touched from many threads — every caller of
    /// connect()/disconnect()/send() (40+ call sites) plus the URLSession
    /// delegate-queue callbacks. Without serialization, concurrent ARC
    /// retain/release on `pingTimer` (a DispatchSourceTimer / OS_dispatch_source)
    /// corrupts its reference count and crashes in libdispatch with
    /// "API MISUSE: Resurrection of an object" (EXC_BREAKPOINT). Every read/write
    /// of the properties above MUST happen on this queue; helpers that assume it
    /// are suffixed `…Locked`.
    private let stateQueue = DispatchQueue(label: "com.havenapp.websocketclient.state")

    deinit {
        // disconnect()'s strong self-capture ensures disconnectLocked() runs
        // before we get here. The session is only nil'd here (or in
        // didBecomeInvalidWithError) — never in disconnectLocked() — so the
        // session stays alive through its internal mach-port teardown.
        pingTimer?.cancel()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        // Safe to nil here: deinit means no other thread holds a strong ref,
        // so no concurrent mutation. If the session was already invalidated
        // by disconnectLocked(), this drops the last external ref and the
        // session finishes cleanup on its own internal retain.
        session?.invalidateAndCancel()
        session = nil
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect(url: URL) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.url = url
            self.disconnectLocked()

            // Never connect: the owner blocked this relay. Reopened by
            // `relayBlocklistChanged` if it is unblocked.
            if RelayBlocklist.isBlocked(url.absoluteString) {
                self.refusedByBlocklist = true
                DispatchQueue.main.async { [weak self] in
                    self?.connectionState = .error
                }
                return
            }

            if !self.isTemporary {
                #if DEBUG
                print("WebSocketClient: Connecting to \(url.absoluteString)")
                #endif
            }

            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .connecting
            }

            var request = URLRequest(url: url)
            request.setValue("Haven/1.0", forHTTPHeaderField: "User-Agent")

            let sess = self.makeSession()
            self.session = sess
            let task = sess.webSocketTask(with: request)
            self.webSocketTask = task
            task.resume()

            self.startPingTimerLocked()
            self.receiveMessagesLocked()
        }
    }

    /// Refused at connect because the relay was blocked. Guarded by `stateQueue`.
    private var refusedByBlocklist = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(relayBlocklistChanged),
                                               name: RelayBlocklist.changed, object: nil)
    }

    /// Blocking a relay drops a socket already open to it; unblocking reopens
    /// one that was refused.
    @objc private func relayBlocklistChanged() {
        stateQueue.async { [weak self] in
            guard let self, let url = self.url else { return }
            let blocked = RelayBlocklist.isBlocked(url.absoluteString)
            if blocked, self.webSocketTask != nil {
                self.disconnectLocked()
                self.refusedByBlocklist = true
                DispatchQueue.main.async { [weak self] in
                    self?.connectionState = .error
                }
            } else if !blocked, self.refusedByBlocklist {
                self.refusedByBlocklist = false
                self.connect(url: url)
            }
        }
    }

    func disconnect() {
        // Strong capture: keeps the client alive until disconnectLocked()
        // actually runs and tears down the timer + session on stateQueue.
        // Without this, callers that drop their reference right after
        // disconnect() (NostrService.resetConnections / handleAccountSwitch)
        // can trigger deinit before the async block executes — the deinit
        // then tears down dispatch/URLSession objects outside stateQueue
        // serialization, racing with the session's internal mach-port
        // cleanup and causing an OS_dispatch_mach_msg use-after-free.
        stateQueue.async {
            self.refusedByBlocklist = false
            self.disconnectLocked()
        }
    }

    /// Tears down the active socket/session/ping timer. MUST run on `stateQueue`.
    private func disconnectLocked() {
        isClosing = true
        stopPingTimerLocked()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        // Invalidate the per-instance session to start async cleanup.
        // Do NOT nil session here — invalidateAndCancel() tears down the
        // session's internal dispatch_mach channels asynchronously. Dropping
        // our reference immediately can free the session mid-cleanup, causing
        // an OS_dispatch_mach_msg use-after-free crash. The session retains
        // us as its delegate; once invalidation completes it calls
        // urlSession(_:didBecomeInvalidWithError:) and releases the delegate
        // ref, which naturally breaks the temporary retain cycle. The session
        // property is then nil'd in that callback (or in deinit as a safety net).
        session?.invalidateAndCancel()
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .disconnected
        }
        isClosing = false
    }

    func send(text: String) {
        stateQueue.async { [weak self] in
            guard let self = self, let task = self.webSocketTask else { return }
            task.send(.string(text)) { error in
                if let error = error {
                    #if DEBUG
                    print("WebSocketClient: Send error: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }

    // MARK: - Liveness

    /// Asks the socket whether it is still there, with a WebSocket ping, and
    /// reports whether it answered before `timeout`.
    ///
    /// `connectionState` is not an answer to that question: a socket the system
    /// killed while the app was suspended still reads `.connected` until the
    /// next keepalive ping notices (up to `pingInterval`). Callers that would
    /// otherwise reconnect blindly — and so pay a fresh relay AUTH signature
    /// through the remote signer — ask this first.
    func probeAlive(timeout: TimeInterval = 3, completion: @escaping (Bool) -> Void) {
        let queue = stateQueue
        queue.async { [weak self] in
            guard let self = self, let task = self.webSocketTask, !self.isClosing else {
                completion(false)
                return
            }
            // `answered` and both closures below run only on `queue`, so the
            // first answer wins without a lock and `completion` runs once.
            var answered = false
            let finish: (Bool) -> Void = { alive in
                guard !answered else { return }
                answered = true
                completion(alive)
            }
            // Deliberately captures `queue`, not `self`: if the client is
            // released while the ping is out, the caller still gets an answer.
            task.sendPing { error in queue.async { finish(error == nil) } }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    // MARK: - Keepalive Ping

    /// MUST run on `stateQueue`.
    private func startPingTimerLocked() {
        stopPingTimerLocked()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Read the socket on the state queue so we never race `webSocketTask`.
            self.stateQueue.async { [weak self] in
                guard let self = self, let task = self.webSocketTask else { return }
                task.sendPing { [weak self] error in
                    if let error = error {
                        self?.stateQueue.async { [weak self] in
                            // Only if this ping was for the socket still in use.
                            guard let self, self.webSocketTask === task else { return }
                            self.stopPingTimerLocked()
                        }
                        #if DEBUG
                        print("WebSocketClient: Ping failed (\(error.localizedDescription)) — marking error")
                        #endif
                        DispatchQueue.main.async { [weak self] in
                            self?.connectionState = .error
                        }
                    }
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    /// MUST run on `stateQueue`.
    private func stopPingTimerLocked() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: - Message Receiving

    /// MUST run on `stateQueue` (reads `webSocketTask`).
    private func receiveMessagesLocked() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    #if DEBUG
                    if !self.isTemporary && self.shouldLogReceive() {
                        print("WebSocketClient: Received: \(text.prefix(80))")
                    }
                    #endif
                    // Dispatch to main thread — PassthroughSubject.send() is not
                    // thread-safe and subscribers observe on MainActor.
                    DispatchQueue.main.async { [weak self] in
                        self?.messageSubject.send(text)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async { [weak self] in
                            self?.messageSubject.send(text)
                        }
                    }
                @unknown default:
                    break
                }
                // Continue receiving — hop back onto stateQueue to read `webSocketTask` safely.
                self.stateQueue.async { [weak self] in self?.receiveMessagesLocked() }
            case .failure(let error):
                self.stateQueue.async { [weak self] in
                    guard let self = self, !self.isClosing else { return }
                    // The socket is dead: its keepalive would only keep
                    // re-marking it as failed every 25 s. Whoever owns the
                    // client reconnects with a new socket and a new timer.
                    self.stopPingTimerLocked()
                    #if DEBUG
                    if self.shouldLogClosed() {
                        print("WebSocketClient: Receive error: \(error.localizedDescription)")
                    }
                    #endif
                    DispatchQueue.main.async { [weak self] in
                        self?.connectionState = .error
                        self?.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    // Throttle logging to avoid excessive debug output
    private var lastReceiveLog: Date = .distantPast
    private func shouldLogReceive() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastReceiveLog) > 2.0 {
            lastReceiveLog = now
            return true
        }
        return false
    }

    private var lastClosedLog: Date = .distantPast
    private func shouldLogClosed() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastClosedLog) > 5.0 {
            lastClosedLog = now
            return true
        }
        return false
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleTLSChallenge(challenge, completionHandler: completionHandler)
    }

    // Task-level TLS challenge — iOS delivers WebSocket auth challenges here
    // rather than the session-level delegate, so both must be implemented.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleTLSChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleTLSChallenge(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        LocalTLSTrust.handle(challenge, completionHandler: completionHandler)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            #if DEBUG
            if !self.isTemporary {
                print("WebSocketClient: Connected to \(self.url?.absoluteString ?? "unknown")")
            }
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .connected
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopPingTimerLocked()
            guard !self.isClosing else { return }
            #if DEBUG
            if self.shouldLogClosed() {
                print("WebSocketClient: Closed with code \(closeCode)")
            }
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .disconnected
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopPingTimerLocked()
            guard let error = error else { return }
            #if DEBUG
            if self.shouldLogClosed() {
                print("WebSocketClient: Completed with error: \(error.localizedDescription)")
            }
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .error
                self?.lastError = error.localizedDescription
            }
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            // Only nil the session if it's the one that just invalidated
            // (connect() may have already replaced it with a new one).
            if self.session === session {
                self.session = nil
            }
        }
    }
}


// MARK: - Bech32 Encoding/Decoding

struct Bech32 {
    static let alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    struct Result {
        let hrp: String
        let data: Data

        var hexString: String {
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func decode(_ bechString: String) -> Result? {
        guard !bechString.isEmpty, bechString.count <= 1000 else { return nil } // Nevents can be long

        let lower = bechString.lowercased()
        guard let pos = lower.lastIndex(of: "1"), pos != lower.startIndex, pos != lower.index(before: lower.endIndex) else { return nil }

        let hrp = String(lower[..<pos])
        let dataString = String(lower[lower.index(after: pos)...])

        var data = [UInt8]()
        for char in dataString {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            data.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: index)))
        }

        guard data.count >= 6 else { return nil }
        // For simplicity, we'll skip full checksum validation in this helper if it's for internal use,
        // but real Nostr libs use it.
        let coreData = Array(data.prefix(data.count - 6))

        // Convert from base32 (5-bit) to base256 (8-bit)
        guard let result = convertBits(data: coreData, from: 5, to: 8, pad: false) else { return nil }
        return Result(hrp: hrp, data: Data(result))
    }

    /// Whether `bechString` carries a valid bech32 checksum. `decode` skips
    /// it, so a mistyped or altered string still decodes to *something*;
    /// callers that will act on the payload (an LNURL to pay) check here.
    static func hasValidChecksum(_ bechString: String) -> Bool {
        let lower = bechString.lowercased()
        guard let pos = lower.lastIndex(of: "1"), pos != lower.startIndex else { return false }
        var data = [UInt8]()
        for char in lower[lower.index(after: pos)...] {
            guard let index = alphabet.firstIndex(of: char) else { return false }
            data.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: index)))
        }
        guard data.count >= 6 else { return false }
        return polymod(expandHrp(String(lower[..<pos])) + data) == 1
    }

    static func encode(hrp: String, data: Data) -> String? {
        guard let converted = convertBits(data: Array(data), from: 8, to: 5, pad: true) else { return nil }

        // Simple Bech32 checksum (NIP-19 uses standard Bech32 for most, or Bech32m depending on spec,
        // but standard Bech32 is common for notes/npubs)
        let checksum = createChecksum(hrp: hrp, data: converted)
        let combined = converted + checksum

        var result = hrp + "1"
        for value in combined {
            let index = alphabet.index(alphabet.startIndex, offsetBy: Int(value))
            result.append(alphabet[index])
        }
        return result
    }

    // MARK: - TLV Helper
    static func encodeTLV(type: UInt8, data: Data) -> Data {
        var result = Data([type])
        result.append(UInt8(data.count))
        result.append(data)
        return result
    }

    // MARK: - Private Helpers

    private static func convertBits(data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        let maxv = (1 << to) - 1

        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (to - bits)) & maxv))
            }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }

        return result
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = expandHrp(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        var result = [UInt8]()
        for i in 0..<6 {
            result.append(UInt8((mod >> (5 * (5 - i))) & 31))
        }
        return result
    }

    private static func expandHrp(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for char in hrp.utf8 {
            result.append(UInt8(char >> 5))
        }
        result.append(0)
        for char in hrp.utf8 {
            result.append(UInt8(char & 31))
        }
        return result
    }

    private static func polymod(_ values: [UInt8]) -> Int {
        let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ Int(value)
            for i in 0..<5 {
                if (top >> i) & 1 == 1 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }

    static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var tempHex = hex
        if tempHex.count % 2 != 0 { return nil }

        while !tempHex.isEmpty {
            let sub = tempHex.prefix(2)
            tempHex = String(tempHex.dropFirst(2))
            if let byte = UInt8(sub, radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
        }
        return data
    }
}

// MARK: - TLS Trust Bypass for Local Relay

/// A URLSession for the local relay, which uses a self-signed certificate.
/// Trust follows `LocalTLSTrust`.
class TLSSkipSession: NSObject, URLSessionDelegate {
    static let shared: URLSession = {
        let delegate = TLSSkipSession()
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        LocalTLSTrust.handle(challenge, completionHandler: completionHandler)
    }
}
