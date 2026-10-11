import Foundation
import Combine

// MARK: - Generic request + history

extension NWCService {
    /// A NIP-47 error the wallet answered with, keeping its code so callers can
    /// tell "this wallet does not do that" from a real failure.
    struct WalletError: Error, LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
        /// The wallet (or this connection's permissions) does not offer the method.
        var isUnsupported: Bool { ["NOT_IMPLEMENTED", "RESTRICTED", "UNAUTHORIZED"].contains(code) }
    }

    /// Sends one NIP-47 request and returns its decrypted `result` object.
    /// Same wire shape as `payInvoice`: sign a kind-23194 with the connection
    /// secret, subscribe for the kind-23195 that tags it, give up after
    /// `timeout` seconds.
    static func call(method: String, params: [String: Any]?, timeout: TimeInterval = 15) async throws -> [String: Any] {
        let nwcURI = ConfigService.shared.config.nwcURI
        guard !nwcURI.isEmpty else { throw NWCError.invalidURI }
        let connData = try parseURI(nwcURI)

        var payload: [String: Any] = ["method": method]
        payload["params"] = params ?? [String: Any]()
        guard let requestData = try? JSONSerialization.data(withJSONObject: payload),
              let requestString = String(data: requestData, encoding: .utf8) else {
            throw NWCError.encryptionError
        }

        let encryptedPayload = try NIP04Service.encrypt(
            plaintext: requestString,
            remotePubkey: connData.pubkey,
            localPrivkey: connData.secret
        )

        guard let localPubkeyCStr = GetPublicKeyC(UnsafeMutablePointer(mutating: (connData.secret as NSString).utf8String)) else {
            throw NWCError.encryptionError
        }
        let localPubkey = String(cString: localPubkeyCStr)
        free(localPubkeyCStr)

        let eventDict: [String: Any] = [
            "pubkey": localPubkey,
            "created_at": Int64(Date().timeIntervalSince1970),
            "kind": 23194,
            "content": encryptedPayload,
            "tags": [["p", connData.pubkey]]
        ]
        guard let eventJsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let eventJsonStr = String(data: eventJsonData, encoding: .utf8),
              let signedCStr = SignEventC(UnsafeMutablePointer(mutating: (eventJsonStr as NSString).utf8String), UnsafeMutablePointer(mutating: (connData.secret as NSString).utf8String)) else {
            throw NWCError.encryptionError
        }
        let signedJsonStr = String(cString: signedCStr)
        free(signedCStr)
        guard let signedData = signedJsonStr.data(using: .utf8),
              let signedEvent = try? JSONDecoder().decode(NostrEvent.self, from: signedData) else {
            throw NWCError.encryptionError
        }

        return try await withCheckedThrowingContinuation { continuation in
            let wsClient = WebSocketClient()
            wsClient.isTemporary = true
            var isCompleted = false
            var cancellable: AnyCancellable? = nil
            var stateCancellable: AnyCancellable? = nil

            func finish(_ result: Result<[String: Any], Error>) {
                guard !isCompleted else { return }
                isCompleted = true
                wsClient.disconnect()
                // Dropping the subscriptions breaks the client -> sink -> client cycle.
                cancellable = nil
                stateCancellable = nil
                continuation.resume(with: result)
            }

            let reqMsg = ["EVENT", [
                "id": signedEvent.id,
                "pubkey": signedEvent.pubkey,
                "created_at": signedEvent.created_at,
                "kind": signedEvent.kind,
                "tags": signedEvent.tags,
                "content": signedEvent.content,
                "sig": signedEvent.sig
            ] as [String: Any]] as [Any]
            let subMsg = ["REQ", UUID().uuidString, [
                "kinds": [23195],
                "authors": [connData.pubkey],
                "#e": [signedEvent.id]
            ] as [String: Any]] as [Any]
            guard let reqData = try? JSONSerialization.data(withJSONObject: reqMsg),
                  let reqStr = String(data: reqData, encoding: .utf8),
                  let subData = try? JSONSerialization.data(withJSONObject: subMsg),
                  let subStr = String(data: subData, encoding: .utf8) else {
                continuation.resume(throwing: NWCError.invalidResponse)
                return
            }

            cancellable = wsClient.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard !isCompleted,
                          let data = message.data(using: .utf8),
                          let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          array.count >= 3,
                          array[0] as? String == "EVENT",
                          let eventObj = array[2] as? [String: Any],
                          let eventData = try? JSONSerialization.data(withJSONObject: eventObj),
                          let responseEvent = try? JSONDecoder().decode(NostrEvent.self, from: eventData) else { return }
                    do {
                        let decrypted = try NIP04Service.decrypt(
                            ciphertext: responseEvent.content,
                            remotePubkey: connData.pubkey,
                            localPrivkey: connData.secret
                        )
                        guard let decData = decrypted.data(using: .utf8),
                              let obj = try JSONSerialization.jsonObject(with: decData) as? [String: Any] else {
                            finish(.failure(NWCError.responseDecodeError))
                            return
                        }
                        if let err = obj["error"] as? [String: Any] {
                            let code = err["code"] as? String ?? "OTHER"
                            let msg = err["message"] as? String ?? code
                            RelayProcessManager.shared.addLog("NWC: \(method) returned \(code): \(msg)", level: "ERROR")
                            finish(.failure(WalletError(code: code, message: msg)))
                        } else {
                            finish(.success(obj["result"] as? [String: Any] ?? [:]))
                        }
                    } catch {
                        let nwcError: NWCError = (error is NIP04Service.NIP04Error) ? .encryptionError : .responseDecodeError
                        finish(.failure(nwcError))
                    }
                }

            stateCancellable = wsClient.$connectionState
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { state in
                    switch state {
                    case .connected:
                        wsClient.send(text: subStr)
                        wsClient.send(text: reqStr)
                    case .error, .disconnected:
                        finish(.failure(NWCError.notConnected))
                    default:
                        break
                    }
                }

            wsClient.connect(url: connData.relayURL)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !isCompleted {
                    RelayProcessManager.shared.addLog("NWC: \(method) timed out after \(Int(timeout))s", level: "ERROR")
                }
                finish(.failure(NWCError.notConnected))
            }
        }
    }

    /// One page of the wallet's payment history, newest first (NIP-47
    /// `list_transactions`). Throws `WalletError` with `isUnsupported` when the
    /// wallet or this connection does not share history.
    static func listTransactions(limit: Int = 30, offset: Int = 0) async throws -> [WalletTransaction] {
        let result = try await call(method: "list_transactions", params: [
            "limit": limit,
            "offset": offset,
            "unpaid": false
        ])
        let raw = result["transactions"] as? [[String: Any]] ?? []
        return WalletTransaction.merge([], raw.compactMap { WalletTransaction(nip47: $0) })
    }
}
