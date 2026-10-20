import Foundation
import Combine

extension NWCService {
    /// Request the NWC wallet to create a Lightning invoice for receiving payments.
    /// - Parameters:
    ///   - amountMsats: Invoice amount in millisatoshis.
    ///   - description: Optional invoice description.
    ///   - expiry: Optional expiry in seconds (wallet default if nil).
    /// - Returns: A bolt11 invoice string.
    static func makeInvoice(amountMsats: Int, description: String? = nil, expiry: Int? = nil) async throws -> String {
        let nwcURI = ConfigService.shared.config.nwcURI
        guard !nwcURI.isEmpty else { throw NWCError.invalidURI }

        let connData = try parseURI(nwcURI)

        // 1. Prepare NWC Request payload
        let params = NWCRequest.NWCParams(amount: amountMsats, description: description, expiry: expiry)
        let request = NWCRequest(method: "make_invoice", params: params)
        let requestData = try JSONEncoder().encode(request)
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            throw NWCError.encryptionError
        }

        // 2. Encrypt Payload using NIP-04
        let encryptedPayload = try NIP04Service.encrypt(
            plaintext: requestString,
            remotePubkey: connData.pubkey,
            localPrivkey: connData.secret
        )

        // 3. Create Nostr Event (Kind 23194)
        guard let localPubkeyCStr = withCStrings([connData.secret], { p in GetPublicKeyC(p[0]) }) else {
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
              let eventJsonStr = String(data: eventJsonData, encoding: .utf8) else {
            throw NWCError.encryptionError
        }

        guard let signedCStr = withCStrings([eventJsonStr, connData.secret], { p in SignEventC(p[0], p[1]) }) else {
            throw NWCError.encryptionError
        }
        let signedJsonStr = String(cString: signedCStr)
        free(signedCStr)

        guard let signedData = signedJsonStr.data(using: .utf8),
              let signedEvent = try? JSONDecoder().decode(NostrEvent.self, from: signedData) else {
            throw NWCError.encryptionError
        }

        // 4. Send via WebSocket and await response
        return try await withCheckedThrowingContinuation { continuation in
            let wsClient = WebSocketClient()
            wsClient.isTemporary = true
            var isCompleted = false

            let reqMsg = ["EVENT", [
                "id": signedEvent.id,
                "pubkey": signedEvent.pubkey,
                "created_at": signedEvent.created_at,
                "kind": signedEvent.kind,
                "tags": signedEvent.tags,
                "content": signedEvent.content,
                "sig": signedEvent.sig
            ] as [String : Any]] as [Any]

            guard let reqData = try? JSONSerialization.data(withJSONObject: reqMsg),
                  let reqStr = String(data: reqData, encoding: .utf8) else {
                continuation.resume(throwing: NWCError.invalidResponse)
                return
            }

            let subId = UUID().uuidString
            let subFilter: [String: Any] = [
                "kinds": [23195],
                "authors": [connData.pubkey],
                "#e": [signedEvent.id]
            ]
            let subMsg = ["REQ", subId, subFilter] as [Any]
            guard let subData = try? JSONSerialization.data(withJSONObject: subMsg),
                  let subStr = String(data: subData, encoding: .utf8) else {
                continuation.resume(throwing: NWCError.invalidResponse)
                return
            }

            var cancellable: Any? = nil
            cancellable = wsClient.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard !isCompleted else { return }
                    if let data = message.data(using: .utf8),
                       let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                       array.count >= 2,
                       let type = array[0] as? String {

                        RelayProcessManager.shared.addLog("NWC: Received make_invoice \(type) from relay", level: "INFO")

                        if type == "EVENT",
                           array.count >= 3,
                           let eventDict = array[2] as? [String: Any],
                           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
                           let responseEvent = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

                            do {
                                let decryptedStr = try NIP04Service.decrypt(
                                    ciphertext: responseEvent.content,
                                    remotePubkey: connData.pubkey,
                                    localPrivkey: connData.secret
                                )
                                #if DEBUG
                                print("NWC: Decrypted make_invoice payload: \(decryptedStr)")
                                #endif

                                if let decData = decryptedStr.data(using: .utf8) {
                                    let responseObj = try JSONDecoder().decode(NWCResponse.self, from: decData)
                                    isCompleted = true
                                    wsClient.disconnect()
                                    _ = cancellable
                                    if let nwcErr = responseObj.error {
                                        RelayProcessManager.shared.addLog("NWC: make_invoice error: \(nwcErr.message)", level: "ERROR")
                                        continuation.resume(throwing: NSError(domain: "NWC", code: 1, userInfo: [NSLocalizedDescriptionKey: nwcErr.message]))
                                    } else if let invoice = responseObj.result?["invoice"]?.value as? String {
                                        continuation.resume(returning: invoice)
                                    } else {
                                        continuation.resume(throwing: NWCError.invalidResponse)
                                    }
                                }
                            } catch {
                                RelayProcessManager.shared.addLog("NWC: make_invoice decode failed: \(error)", level: "ERROR")
                                isCompleted = true
                                wsClient.disconnect()
                                let nwcError: NWCError = (error is NIP04Service.NIP04Error) ? .encryptionError : .responseDecodeError
                                continuation.resume(throwing: nwcError)
                            }
                        } else if type == "NOTICE", array.count >= 2, let msg = array[1] as? String {
                            RelayProcessManager.shared.addLog("NWC: make_invoice NOTICE: \(msg)", level: "WARN")
                        } else if type == "OK" {
                            RelayProcessManager.shared.addLog("NWC: make_invoice OK", level: "INFO")
                        }
                    }
                }

            var stateCancellable: Any? = nil
            stateCancellable = wsClient.$connectionState
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        RelayProcessManager.shared.addLog("NWC: make_invoice WebSocket connected", level: "INFO")
                        wsClient.send(text: subStr)
                        wsClient.send(text: reqStr)
                    } else if state == .error {
                        if !isCompleted {
                            isCompleted = true
                            RelayProcessManager.shared.addLog("NWC: make_invoice connection error", level: "ERROR")
                            continuation.resume(throwing: NWCError.notConnected)
                        }
                    } else if state == .disconnected {
                        if !isCompleted {
                            isCompleted = true
                            RelayProcessManager.shared.addLog("NWC: make_invoice disconnected prematurely", level: "ERROR")
                            continuation.resume(throwing: NWCError.notConnected)
                        }
                    }
                }

            RelayProcessManager.shared.addLog("NWC: Connecting for make_invoice to \(connData.relayURL.host ?? "relay")...", level: "INFO")
            wsClient.connect(url: connData.relayURL)

            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if !isCompleted {
                    isCompleted = true
                    wsClient.disconnect()
                    _ = cancellable
                    _ = stateCancellable
                    RelayProcessManager.shared.addLog("NWC: make_invoice timeout after 15s", level: "ERROR")
                    continuation.resume(throwing: NWCError.notConnected)
                }
            }
        }
    }
}
