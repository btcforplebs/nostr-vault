import Foundation

@MainActor
struct NWCService {
    enum NWCError: Error, LocalizedError {
        case invalidURI
        case notConnected
        case invalidResponse
        case encryptionError
        
        var errorDescription: String? {
            switch self {
            case .invalidURI: return "Invalid NWC URI"
            case .notConnected: return "Failed to connect to NWC relay"
            case .invalidResponse: return "Invalid response from NWC relay"
            case .encryptionError: return "Failed to encrypt/decrypt payload"
            }
        }
    }

    struct NWCRequest: Encodable {
        let method: String
        let params: NWCParams?

        struct NWCParams: Encodable {
            var invoice: String?
            var amount: Int?
            var description: String?
            var expiry: Int?

            enum CodingKeys: String, CodingKey {
                case invoice, amount, description, expiry
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let invoice { try container.encode(invoice, forKey: .invoice) }
                if let amount { try container.encode(amount, forKey: .amount) }
                if let description { try container.encode(description, forKey: .description) }
                if let expiry { try container.encode(expiry, forKey: .expiry) }
            }
        }
    }

    struct CodableAny: Codable {
        let value: Any
        init(_ value: Any) { self.value = value }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) { value = intVal }
            else if let doubleVal = try? container.decode(Double.self) { value = doubleVal }
            else if let boolVal = try? container.decode(Bool.self) { value = boolVal }
            else if let strVal = try? container.decode(String.self) { value = strVal }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown type") }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let intVal = value as? Int { try container.encode(intVal) }
            else if let doubleVal = value as? Double { try container.encode(doubleVal) }
            else if let boolVal = value as? Bool { try container.encode(boolVal) }
            else if let strVal = value as? String { try container.encode(strVal) }
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Invalid JSON value")) }
        }
    }
    
    struct NWCResponse: Decodable {
        let result_type: String?
        let result: [String: CodableAny]?
        let error: NIP47Error?
    }
    
    struct NIP47Error: Decodable {
        let code: String
        let message: String
    }
    
    struct NWCConnectionData {
        let relayURL: URL
        let secret: String
        let pubkey: String
    }
    
    static func parseURI(_ uri: String) throws -> NWCConnectionData {
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle both nostr+walletconnect:// and nostr+walletconnect:
        let scheme = "nostr+walletconnect"
        var workingURI = trimmedURI
        if trimmedURI.hasPrefix("\(scheme)://") {
            // Already in standard URL format
        } else if trimmedURI.hasPrefix("\(scheme):") {
            // Convert to // format for URLComponents to find host
            let suffix = trimmedURI.dropFirst("\(scheme):".count)
            workingURI = "\(scheme)://\(suffix)"
        } else {
            throw NWCError.invalidURI
        }
        
        guard let urlComponents = URLComponents(string: workingURI) else {
            #if DEBUG
            print("NWCService: URLComponents failed to parse \(workingURI)")
            #endif
            throw NWCError.invalidURI
        }
        
        // Host might be nil if scheme is unknown and URL is not standard,
        // but since we forced :// it should work. 
        // fallback: extract path if host is nil
        let pubkey = urlComponents.host ?? urlComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        guard !pubkey.isEmpty else {
            #if DEBUG
            print("NWCService: Could not extract pubkey from \(workingURI)")
            #endif
            throw NWCError.invalidURI
        }
        
        guard let queryItems = urlComponents.queryItems else {
            #if DEBUG
            print("NWCService: No query items in \(workingURI)")
            #endif
            throw NWCError.invalidURI
        }
        
        guard let relayString = queryItems.first(where: { $0.name == "relay" })?.value,
              let relayURL = URL(string: relayString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let secret = queryItems.first(where: { $0.name == "secret" })?.value else {
            #if DEBUG
            print("NWCService: Missing relay or secret in \(workingURI)")
            #endif
            throw NWCError.invalidURI
        }
        
        RelayProcessManager.shared.addLog("NWC: Successfully parsed URI for relay \(relayURL.host ?? "unknown")", level: "DEBUG")
        return NWCConnectionData(relayURL: relayURL, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), pubkey: pubkey)
    }
    
    static func payInvoice(bolt11: String) async throws -> String {
        let nwcURI = ConfigService.shared.config.nwcURI
        guard !nwcURI.isEmpty else { throw NWCError.invalidURI }
        
        let connData = try parseURI(nwcURI)
        
        // 1. Prepare NWC Request payload
        let request = NWCRequest(method: "pay_invoice", params: NWCRequest.NWCParams(invoice: bolt11))
        let requestData = try JSONEncoder().encode(request)
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            throw NWCError.encryptionError
        }
        
        // 2. Encrypt Payload using NIP-04 (Wallet Secret is our private key, Wallet Pubkey is remote)
        let encryptedPayload = try NIP04Service.encrypt(
            plaintext: requestString,
            remotePubkey: connData.pubkey,
            localPrivkey: connData.secret
        )
        
        // 3. Create Nostr Event (Kind 23194)
        // We need a local pubkey derived from the secret
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
              let eventJsonStr = String(data: eventJsonData, encoding: .utf8) else {
            throw NWCError.encryptionError
        }
        
        // Sign event using the secret
        guard let signedCStr = SignEventC(UnsafeMutablePointer(mutating: (eventJsonStr as NSString).utf8String), UnsafeMutablePointer(mutating: (connData.secret as NSString).utf8String)) else {
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
                        
                        RelayProcessManager.shared.addLog("NWC: Received \(type) from relay", level: "INFO")
                        
                        if type == "EVENT",
                           array.count >= 3,
                           let eventDict = array[2] as? [String: Any],
                           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
                           let responseEvent = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
                            
                            // Decrypt response
                            do {
                                let decryptedStr = try NIP04Service.decrypt(
                                    ciphertext: responseEvent.content,
                                    remotePubkey: connData.pubkey,
                                    localPrivkey: connData.secret
                                )
                                RelayProcessManager.shared.addLog("NWC: Decrypted response payload: \(decryptedStr)", level: "DEBUG")
                                
                                if let decData = decryptedStr.data(using: .utf8) {
                                    let responseObj = try JSONDecoder().decode(NWCResponse.self, from: decData)
                                    isCompleted = true
                                    wsClient.disconnect()
                                    _ = cancellable // extend lifetime
                                    if let nwcErr = responseObj.error {
                                        RelayProcessManager.shared.addLog("NWC: Relay returned error: \(nwcErr.message)", level: "ERROR")
                                        continuation.resume(throwing: NSError(domain: "NWC", code: 1, userInfo: [NSLocalizedDescriptionKey: nwcErr.message]))
                                    } else if let preimage = responseObj.result?["preimage"]?.value as? String {
                                        continuation.resume(returning: preimage)
                                    } else {
                                        continuation.resume(returning: "Success")
                                    }
                                }
                            } catch {
                                RelayProcessManager.shared.addLog("NWC: Failed to decrypt or decode response: \(error)", level: "ERROR")
                                isCompleted = true
                                wsClient.disconnect()
                                continuation.resume(throwing: NWCError.encryptionError)
                            }
                        } else if type == "OK" {
                            RelayProcessManager.shared.addLog("NWC: OK response: \(array.count > 2 ? String(describing: array[2]) : "no message")", level: "INFO")
                        } else if type == "NOTICE", array.count >= 2, let msg = array[1] as? String {
                            RelayProcessManager.shared.addLog("NWC: NOTICE from relay: \(msg)", level: "WARN")
                        } else if type == "AUTH" {
                            #if DEBUG
                            print("NWCService: Relay requested AUTH (not implemented)")
                            #endif
                        } else {
                            #if DEBUG
                            print("NWCService: Unhandled message type \(type) or malformed payload")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("NWCService: Could not parse raw message: \(message)")
                        #endif
                    }
                }
            
            var stateCancellable: Any? = nil
            stateCancellable = wsClient.$connectionState
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        RelayProcessManager.shared.addLog("NWC: WebSocket connected to \(connData.relayURL.host ?? "relay")", level: "INFO")
                        RelayProcessManager.shared.addLog("NWC: Sending request", level: "DEBUG")
                        wsClient.send(text: subStr)
                        wsClient.send(text: reqStr)
                    } else if state == .error {
                        if !isCompleted {
                            isCompleted = true
                            RelayProcessManager.shared.addLog("NWC: Connection error", level: "ERROR")
                            continuation.resume(throwing: NWCError.notConnected)
                        }
                    } else if state == .disconnected {
                        if !isCompleted {
                            isCompleted = true
                            RelayProcessManager.shared.addLog("NWC: WebSocket disconnected prematurely", level: "ERROR")
                            continuation.resume(throwing: NWCError.notConnected)
                        }
                    }
                }
            
            RelayProcessManager.shared.addLog("NWC: Connecting to \(connData.relayURL.absoluteString)...", level: "INFO")
            wsClient.connect(url: connData.relayURL)
            
            // Timeout after 15 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if !isCompleted {
                    isCompleted = true
                    wsClient.disconnect()
                    _ = cancellable
                    _ = stateCancellable
                    RelayProcessManager.shared.addLog("NWC: Connection or response timeout after 15s", level: "ERROR")
                    continuation.resume(throwing: NWCError.notConnected)
                }
            }
        }
    }
    
    static func getBalance() async throws -> Int {
        let nwcURI = ConfigService.shared.config.nwcURI
        guard !nwcURI.isEmpty else { throw NWCError.invalidURI }
        
        let connData = try parseURI(nwcURI)
        
        // 1. Prepare NWC Request payload
        let request = NWCRequest(method: "get_balance", params: nil)
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
              let eventJsonStr = String(data: eventJsonData, encoding: .utf8) else {
            throw NWCError.encryptionError
        }
        
        guard let signedCStr = SignEventC(UnsafeMutablePointer(mutating: (eventJsonStr as NSString).utf8String), UnsafeMutablePointer(mutating: (connData.secret as NSString).utf8String)) else {
            throw NWCError.encryptionError
        }
        let signedJsonStr = String(cString: signedCStr)
        free(signedCStr)
        
        guard let signedData = signedJsonStr.data(using: .utf8),
              let signedEvent = try? JSONDecoder().decode(NostrEvent.self, from: signedData) else {
            throw NWCError.encryptionError
        }
        
        // 4. Send via WebSocket
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
                        
                        RelayProcessManager.shared.addLog("NWC: Received balance \(type) from relay", level: "INFO")
                        
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
                                RelayProcessManager.shared.addLog("NWC: Decrypted balance payload: \(decryptedStr)", level: "DEBUG")
                                
                                if let decData = decryptedStr.data(using: .utf8) {
                                    let responseObj = try JSONDecoder().decode(NWCResponse.self, from: decData)
                                    isCompleted = true
                                    wsClient.disconnect()
                                    _ = cancellable
                                    if let nwcErr = responseObj.error {
                                        RelayProcessManager.shared.addLog("NWC: Balance error from relay: \(nwcErr.message)", level: "ERROR")
                                        continuation.resume(throwing: NSError(domain: "NWC", code: 1, userInfo: [NSLocalizedDescriptionKey: nwcErr.message]))
                                    } else if let balanceVal = responseObj.result?["balance"]?.value {
                                        RelayProcessManager.shared.addLog("NWC: Extracted balance value: \(balanceVal)", level: "INFO")
                                        if let balance = balanceVal as? Int {
                                            continuation.resume(returning: balance)
                                        } else if let balanceStr = balanceVal as? String, let balance = Int(balanceStr) {
                                            continuation.resume(returning: balance)
                                        } else if let balanceDbl = balanceVal as? Double {
                                            continuation.resume(returning: Int(balanceDbl))
                                        } else {
                                            continuation.resume(throwing: NWCError.invalidResponse)
                                        }
                                    } else {
                                        continuation.resume(throwing: NWCError.invalidResponse)
                                    }
                                }
                            } catch {
                                RelayProcessManager.shared.addLog("NWC: Balance decode failed: \(error)", level: "ERROR")
                                isCompleted = true
                                wsClient.disconnect()
                                continuation.resume(throwing: NWCError.encryptionError)
                            }
                        } else if type == "NOTICE", array.count >= 2, let msg = array[1] as? String {
                            RelayProcessManager.shared.addLog("NWC: Balance NOTICE: \(msg)", level: "WARN")
                        } else if type == "OK" {
                            RelayProcessManager.shared.addLog("NWC: Balance OK response: \(array.count > 2 ? String(describing: array[2]) : "no message")", level: "INFO")
                        } else {
                            #if DEBUG
                            print("NWCService: Unhandled balance message type \(type)")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("NWCService: Could not parse raw balance message: \(message)")
                        #endif
                    }
                }
            
            var stateCancellable: Any? = nil
            stateCancellable = wsClient.$connectionState
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        RelayProcessManager.shared.addLog("NWC: Balance WebSocket connected", level: "INFO")
                        RelayProcessManager.shared.addLog("NWC: Sending balance request", level: "DEBUG")
                        wsClient.send(text: subStr)
                        wsClient.send(text: reqStr)
                    } else if state == .error {
                        if !isCompleted {
                            isCompleted = true
                            RelayProcessManager.shared.addLog("NWC: Balance connection error", level: "ERROR")
                            continuation.resume(throwing: NWCError.notConnected)
                        }
                    } else if state == .disconnected {
                        if !isCompleted {
                            isCompleted = true
                            RelayProcessManager.shared.addLog("NWC: Balance WebSocket disconnected prematurely", level: "ERROR")
                            continuation.resume(throwing: NWCError.notConnected)
                        }
                    }
                }
            
            RelayProcessManager.shared.addLog("NWC: Connecting for balance to \(connData.relayURL.host ?? "relay")...", level: "INFO")
            wsClient.connect(url: connData.relayURL)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if !isCompleted {
                    isCompleted = true
                    wsClient.disconnect()
                    _ = cancellable
                    _ = stateCancellable
                    RelayProcessManager.shared.addLog("NWC: Connection or response timeout after 15s", level: "ERROR")
                    continuation.resume(throwing: NWCError.notConnected)
                }
            }
        }
    }

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
              let eventJsonStr = String(data: eventJsonData, encoding: .utf8) else {
            throw NWCError.encryptionError
        }

        guard let signedCStr = SignEventC(UnsafeMutablePointer(mutating: (eventJsonStr as NSString).utf8String), UnsafeMutablePointer(mutating: (connData.secret as NSString).utf8String)) else {
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
                                RelayProcessManager.shared.addLog("NWC: Decrypted make_invoice payload: \(decryptedStr)", level: "DEBUG")

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
                                continuation.resume(throwing: NWCError.encryptionError)
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
