import Foundation
@preconcurrency import Combine

/// Lightweight pure-Swift NIP-46 handshake using URLSessionWebSocketTask + Go crypto bridge.
/// Performs the initial "connect" + "get_public_key" RPC exchange during setup,
/// bypassing the Go pool subscription that fails to receive signer responses.
enum SwiftNIP46Handshake {

    enum HandshakeError: Error, LocalizedError {
        case invalidBunkerURI
        case keypairGenerationFailed
        case webSocketConnectionFailed
        case encryptionFailed
        case signingFailed
        case timeout
        case signerRejected(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidBunkerURI: return "Invalid bunker:// URI"
            case .keypairGenerationFailed: return "Failed to generate client keypair"
            case .webSocketConnectionFailed: return "Failed to connect to relay"
            case .encryptionFailed: return "Failed to encrypt NIP-46 request"
            case .signingFailed: return "Failed to sign NIP-46 event"
            case .timeout: return "Remote signer did not respond in time"
            case .signerRejected(let msg): return "Signer rejected: \(msg)"
            case .invalidResponse(let detail): return "Invalid response: \(detail)"
            }
        }
    }

    struct HandshakeResult {
        let userPubkey: String
        let clientSecretKey: String
        let clientPubkey: String
    }

    /// Performs the full NIP-46 connect handshake over a direct WebSocket.
    static func performHandshake(
        bunkerURI: String,
        existingClientSK: String? = nil,
        existingClientPK: String? = nil,
        timeoutSeconds: TimeInterval = 45
    ) async throws -> HandshakeResult {
        let info = try await MainActor.run { try NIP46Service.parseBunkerURI(bunkerURI) }

        // Reuse existing client keypair if provided, otherwise generate a new one
        let clientSK: String
        let clientPK: String
        if let sk = existingClientSK, let pk = existingClientPK, !sk.isEmpty, !pk.isEmpty {
            clientSK = sk
            clientPK = pk
        } else {
            guard let keyPairCStr = GenerateKeyPairC() else {
                throw HandshakeError.keypairGenerationFailed
            }
            let keyPairStr = String(cString: keyPairCStr)
            free(keyPairCStr)

            let parts = keyPairStr.split(separator: ":")
            guard parts.count == 2 else {
                throw HandshakeError.keypairGenerationFailed
            }
            clientSK = String(parts[0])
            clientPK = String(parts[1])
        }

        guard let relayURL = URL(string: info.relayURL) else {
            throw HandshakeError.invalidBunkerURI
        }

        // Create temporary WebSocket
        let ws = WebSocketClient()
        ws.isTemporary = true

        // Connect and wait for WebSocket to be ready
        try await connectWebSocket(ws, url: relayURL, timeout: 10)

        defer { ws.disconnect() }

        // Step 1: "connect" RPC
        let connectResponse = try await sendRPC(
            ws: ws,
            method: "connect",
            params: [info.signerPubkey, info.secret],
            clientSK: clientSK,
            clientPK: clientPK,
            signerPubkey: info.signerPubkey,
            timeout: timeoutSeconds
        )

        if let error = connectResponse.error, !error.isEmpty {
            throw HandshakeError.signerRejected(error)
        }

        // Step 2: "get_public_key" RPC
        let pkResponse = try await sendRPC(
            ws: ws,
            method: "get_public_key",
            params: [],
            clientSK: clientSK,
            clientPK: clientPK,
            signerPubkey: info.signerPubkey,
            timeout: timeoutSeconds
        )

        if let error = pkResponse.error, !error.isEmpty {
            throw HandshakeError.signerRejected(error)
        }

        guard let userPubkey = pkResponse.result,
              userPubkey.count == 64,
              userPubkey.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw HandshakeError.invalidResponse("get_public_key did not return valid hex pubkey")
        }

        return HandshakeResult(
            userPubkey: userPubkey,
            clientSecretKey: clientSK,
            clientPubkey: clientPK
        )
    }

    // MARK: - Private

    /// Mutable state shared across @Sendable closures within a single continuation.
    /// All access occurs on the main queue, making this safe despite @unchecked.
    private final class ContinuationState: @unchecked Sendable {
        var resolved = false
        var cancellable: AnyCancellable?
    }

    private struct RPCResponse {
        let result: String?
        let error: String?
    }

    /// Wait for WebSocket to reach connected state.
    private static func connectWebSocket(_ ws: WebSocketClient, url: URL, timeout: TimeInterval) async throws {
        ws.connect(url: url)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = ContinuationState()

            state.cancellable = ws.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { connState in
                    guard !state.resolved else { return }
                    if connState == .connected {
                        state.resolved = true
                        state.cancellable?.cancel()
                        continuation.resume()
                    } else if connState == .error {
                        state.resolved = true
                        state.cancellable?.cancel()
                        continuation.resume(throwing: HandshakeError.webSocketConnectionFailed)
                    }
                }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !state.resolved {
                    state.resolved = true
                    state.cancellable?.cancel()
                    continuation.resume(throwing: HandshakeError.webSocketConnectionFailed)
                }
            }
        }
    }

    /// Send a single NIP-46 RPC and wait for the response.
    private static func sendRPC(
        ws: WebSocketClient,
        method: String,
        params: [String],
        clientSK: String,
        clientPK: String,
        signerPubkey: String,
        timeout: TimeInterval
    ) async throws -> RPCResponse {
        let requestId = UUID().uuidString

        // Build RPC JSON payload
        let rpcDict: [String: Any] = ["id": requestId, "method": method, "params": params]
        guard let rpcData = try? JSONSerialization.data(withJSONObject: rpcDict),
              let rpcString = String(data: rpcData, encoding: .utf8) else {
            throw HandshakeError.encryptionFailed
        }

        // Encrypt with NIP-44
        guard let encCStr = withCStrings([rpcString, signerPubkey, clientSK], { p in EncryptNIP44C(p[0], p[1], p[2]) }) else {
            throw HandshakeError.encryptionFailed
        }
        let encryptedContent = String(cString: encCStr)
        free(encCStr)

        // Build unsigned event JSON for SignEventC
        let createdAt = Int64(Date().timeIntervalSince1970)
        let eventDict: [String: Any] = [
            "pubkey": clientPK,
            "created_at": createdAt,
            "kind": 24133,
            "content": encryptedContent,
            "tags": [["p", signerPubkey]]
        ]
        guard let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
              let eventJSON = String(data: eventData, encoding: .utf8) else {
            throw HandshakeError.signingFailed
        }

        // Sign with Go bridge
        guard let signedCStr = withCStrings([eventJSON, clientSK], { p in SignEventC(p[0], p[1]) }) else {
            throw HandshakeError.signingFailed
        }
        let signedJSON = String(cString: signedCStr)
        free(signedCStr)

        // Build relay messages
        let subId = "nip46-\(requestId.prefix(8))"
        let since = createdAt - 5
        let filterDict: [String: Any] = [
            "kinds": [24133],
            "#p": [clientPK],
            "since": since
        ]
        guard let filterData = try? JSONSerialization.data(withJSONObject: filterDict),
              let filterJSON = String(data: filterData, encoding: .utf8) else {
            throw HandshakeError.signingFailed
        }

        let reqMsg = "[\"REQ\",\"\(subId)\",\(filterJSON)]"
        let eventMsg = "[\"EVENT\",\(signedJSON)]"

        // Subscribe, send event, and await response
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RPCResponse, Error>) in
            let state = ContinuationState()

            state.cancellable = ws.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard !state.resolved else { return }
                    guard let data = message.data(using: .utf8),
                          let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          array.count >= 2,
                          let msgType = array[0] as? String else { return }

                    if msgType == "EVENT", array.count >= 3,
                       let evtDict = array[2] as? [String: Any],
                       let evtPubkey = evtDict["pubkey"] as? String,
                       evtPubkey == signerPubkey,
                       let evtContent = evtDict["content"] as? String {

                        // Decrypt the response
                        guard let decCStr = withCStrings([evtContent, signerPubkey, clientSK], { p in DecryptNIP44C(p[0], p[1], p[2]) }) else { return }
                        let decrypted = String(cString: decCStr)
                        free(decCStr)

                        // Parse NIP-46 response
                        guard let respData = decrypted.data(using: .utf8),
                              let respDict = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                              let respId = respDict["id"] as? String,
                              respId == requestId else { return }

                        state.resolved = true
                        state.cancellable?.cancel()

                        // Close subscription
                        ws.send(text: "[\"CLOSE\",\"\(subId)\"]")

                        let error = respDict["error"] as? String
                        let result = respDict["result"] as? String
                        continuation.resume(returning: RPCResponse(result: result, error: error))
                    }
                }

            // Send subscription then event
            ws.send(text: reqMsg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard !state.resolved else { return }
                ws.send(text: eventMsg)
            }

            // Timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !state.resolved {
                    state.resolved = true
                    state.cancellable?.cancel()
                    ws.send(text: "[\"CLOSE\",\"\(subId)\"]")
                    continuation.resume(throwing: HandshakeError.timeout)
                }
            }
        }
    }
}
