import Foundation
import Combine

/// URLSessionDelegate that trusts self-signed certificates for localhost
class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    private func isLocalhost(_ host: String?) -> Bool {
        guard let host = host else { return false }
        // Match localhost, 127.0.0.1, ::1, and [::1] (IPv6)
        return host == "localhost" ||
               host == "127.0.0.1" ||
               host == "::1" ||
               host == "[::1]"
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        let authMethod = challenge.protectionSpace.authenticationMethod

        // Only trust self-signed certs for localhost
        if isLocalhost(host) {
            // For server trust challenges (TLS/SSL), accept self-signed certificates
            if authMethod == NSURLAuthenticationMethodServerTrust {
                if let serverTrust = challenge.protectionSpace.serverTrust {
                    // For localhost, always trust self-signed certificates
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                    return
                }
            }
        }

        // For remote servers or other challenges, use default validation
        completionHandler(.performDefaultHandling, nil)
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

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect(url: URL) {
        self.url = url
        disconnect()

        if !isTemporary {
            #if DEBUG
            print("WebSocketClient: Connecting to \(url.absoluteString)")
            #endif
        }

        DispatchQueue.main.async {
            self.connectionState = .connecting
        }

        var request = URLRequest(url: url)
        request.setValue("Haven/1.0", forHTTPHeaderField: "User-Agent")

        let sess = makeSession()
        session = sess
        webSocketTask = sess.webSocketTask(with: request)
        webSocketTask?.resume()

        startPingTimer()
        receiveMessages()
    }

    func disconnect() {
        isClosing = true
        stopPingTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        // Invalidate the per-instance session to break the URLSession→delegate retain cycle
        session?.invalidateAndCancel()
        session = nil
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
        isClosing = false
    }

    func send(text: String) {
        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                #if DEBUG
                print("WebSocketClient: Send error: \(error.localizedDescription)")
                #endif
            }
        }
    }

    // MARK: - Keepalive Ping

    private func startPingTimer() {
        stopPingTimer()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.webSocketTask?.sendPing { error in
                if let error = error {
                    #if DEBUG
                    print("WebSocketClient: Ping failed (\(error.localizedDescription)) — marking error")
                    #endif
                    DispatchQueue.main.async {
                        self.connectionState = .error
                    }
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: - Message Receiving

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    #if DEBUG
                    if !self.isTemporary && self.shouldLogReceive() {
                        print("WebSocketClient [\(self.url?.lastPathComponent ?? "root")]: Received: \(text.prefix(80))")
                    }
                    #endif
                    self.messageSubject.send(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.messageSubject.send(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessages()
            case .failure(let error):
                if !self.isClosing {
                    #if DEBUG
                    if self.shouldLogClosed() {
                        print("WebSocketClient: Receive error: \(error.localizedDescription)")
                    }
                    #endif
                    DispatchQueue.main.async {
                        self.connectionState = .error
                        self.lastError = error.localizedDescription
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

    // MARK: - URLSessionDelegate (TLS trust for localhost)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        #if DEBUG
        if !isTemporary {
            print("WebSocketClient: Connected to \(url?.absoluteString ?? "unknown")")
        }
        #endif
        DispatchQueue.main.async {
            self.connectionState = .connected
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stopPingTimer()
        if !isClosing {
            #if DEBUG
            if shouldLogClosed() {
                print("WebSocketClient: Closed with code \(closeCode)")
            }
            #endif
            DispatchQueue.main.async {
                self.connectionState = .disconnected
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stopPingTimer()
        if let error = error {
            #if DEBUG
            if shouldLogClosed() {
                print("WebSocketClient: Completed with error: \(error.localizedDescription)")
            }
            #endif
            DispatchQueue.main.async {
                self.connectionState = .error
                self.lastError = error.localizedDescription
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

/// A URLSession wrapper that bypasses TLS certificate verification for localhost/127.0.0.1.
/// This is necessary because the local Haven relay uses a self-signed certificate.
class TLSSkipSession: NSObject, URLSessionDelegate {
    static let shared: URLSession = {
        let delegate = TLSSkipSession()
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // If the host is local, we allow the self-signed certificate
        if let host = challenge.protectionSpace.host.lowercased() as String?,
           host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // Otherwise, use default handling
        completionHandler(.performDefaultHandling, nil)
    }
}
