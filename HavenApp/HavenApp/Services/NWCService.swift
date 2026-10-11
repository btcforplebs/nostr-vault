import Foundation
import Combine

@MainActor
struct NWCService {
    enum NWCError: Error, LocalizedError {
        case invalidURI
        case notConnected
        case invalidResponse
        case encryptionError
        case responseDecodeError

        var errorDescription: String? {
            switch self {
            case .invalidURI: return "Invalid NWC URI"
            case .notConnected: return "Failed to connect to NWC relay"
            case .invalidResponse: return "Invalid response from NWC relay"
            case .encryptionError: return "Failed to encrypt/decrypt NWC payload"
            case .responseDecodeError: return "Wallet returned an unexpected response format"
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
            if container.decodeNil() { value = NSNull() }
            else if let intVal = try? container.decode(Int.self) { value = intVal }
            else if let doubleVal = try? container.decode(Double.self) { value = doubleVal }
            else if let boolVal = try? container.decode(Bool.self) { value = boolVal }
            else if let strVal = try? container.decode(String.self) { value = strVal }
            else if let arrVal = try? container.decode([CodableAny].self) { value = arrVal.map { $0.value } }
            else if let dictVal = try? container.decode([String: CodableAny].self) { value = dictVal.mapValues { $0.value } }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type") }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if value is NSNull { try container.encodeNil() }
            else if let intVal = value as? Int { try container.encode(intVal) }
            else if let doubleVal = value as? Double { try container.encode(doubleVal) }
            else if let boolVal = value as? Bool { try container.encode(boolVal) }
            else if let strVal = value as? String { try container.encode(strVal) }
            else if let arrVal = value as? [Any] { try container.encode(arrVal.map { CodableAny($0) }) }
            else if let dictVal = value as? [String: Any] { try container.encode(dictVal.mapValues { CodableAny($0) }) }
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported JSON type")) }
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
}
