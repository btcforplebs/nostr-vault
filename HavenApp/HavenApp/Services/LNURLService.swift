import Foundation

@MainActor
enum LNURLService {
    enum LNURLError: Error, LocalizedError {
        case invalidAddress
        case networkError(Error)
        case invalidResponse
        case invalidInvoice
        
        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "Invalid Lightning Address"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .invalidResponse: return "Invalid response from LNURL service"
            case .invalidInvoice: return "Failed to retrieve a valid invoice"
            }
        }
    }
    
    struct LNURLPayResponse: Decodable {
        let callback: String
        let maxSendable: Int
        let minSendable: Int
        let metadata: String
        let tag: String
        let nostrPubkey: String?
        let allowsNostr: Bool?
    }
    
    struct LNURLCallbackResponse: Decodable {
        let pr: String
        let routes: [[String: String]]?
    }
    
    /// Resolves a Lightning Address (lud16) format (user@domain.com) to an LNURL Pay Response.
    static func resolveAddress(_ lud16: String) async throws -> LNURLPayResponse {
        let parts = lud16.components(separatedBy: "@")
        guard parts.count == 2 else {
            throw LNURLError.invalidAddress
        }
        
        let username = parts[0].lowercased().addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? parts[0].lowercased()
        let domain = parts[1].lowercased()
        
        guard let url = URL(string: "https://\(domain)/.well-known/lnurlp/\(username)") else {
            throw LNURLError.invalidAddress
        }
        
        RelayProcessManager.shared.addLog("LNURL: Resolving \(url.absoluteString)", level: "DEBUG")
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LNURLError.invalidResponse
        }
        
        RelayProcessManager.shared.addLog("LNURL: Resolution status: \(httpResponse.statusCode)", level: "DEBUG")
        
        guard httpResponse.statusCode == 200 else {
            if let body = String(data: data, encoding: .utf8) {
                RelayProcessManager.shared.addLog("LNURL: Error body: \(body)", level: "DEBUG")
            }
            throw LNURLError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(LNURLPayResponse.self, from: data)
        } catch {
            RelayProcessManager.shared.addLog("LNURL: Decoding failed: \(error.localizedDescription)", level: "ERROR")
            if let body = String(data: data, encoding: .utf8) {
                RelayProcessManager.shared.addLog("LNURL: Raw body: \(body)", level: "DEBUG")
            }
            throw LNURLError.invalidResponse
        }
    }
    
    /// Fetches a Bolt11 invoice by calling the LNURL callback with an amount and optionally a Nostr Zap Request
    static func fetchInvoice(callback: String, amountMsat: Int, zapRequest: NostrEvent?) async throws -> String {
        guard var urlComponents = URLComponents(string: callback) else {
            throw LNURLError.invalidResponse
        }
        
        var queryItems = urlComponents.queryItems ?? []
        queryItems.append(URLQueryItem(name: "amount", value: String(amountMsat)))
        
        if let zapRequest = zapRequest {
            if let eventData = try? JSONEncoder().encode(zapRequest),
               let eventString = String(data: eventData, encoding: .utf8) {
                queryItems.append(URLQueryItem(name: "nostr", value: eventString))
            }
        }
        
        urlComponents.queryItems = queryItems
        
        guard let url = urlComponents.url else {
            throw LNURLError.invalidResponse
        }
        
        RelayProcessManager.shared.addLog("LNURL: Fetching invoice from \(url.absoluteString)", level: "DEBUG")
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LNURLError.invalidResponse
        }
        
        RelayProcessManager.shared.addLog("LNURL: Callback status: \(httpResponse.statusCode)", level: "DEBUG")
        
        guard httpResponse.statusCode == 200 else {
            if let body = String(data: data, encoding: .utf8) {
                RelayProcessManager.shared.addLog("LNURL: Error body: \(body)", level: "DEBUG")
            }
            throw LNURLError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        do {
            let callbackResponse = try decoder.decode(LNURLCallbackResponse.self, from: data)
            return callbackResponse.pr
        } catch {
            RelayProcessManager.shared.addLog("LNURL: Callback decoding failed: \(error.localizedDescription)", level: "ERROR")
            if let body = String(data: data, encoding: .utf8) {
                RelayProcessManager.shared.addLog("LNURL: Raw body: \(body)", level: "DEBUG")
            }
            throw LNURLError.invalidInvoice
        }
    }
}
