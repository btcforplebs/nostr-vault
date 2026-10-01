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
        /// LUD-12: longest comment the service accepts; nil or 0 means none.
        var commentAllowed: Int? = nil
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
        
        return try await fetchPayResponse(from: url)
    }
    
    /// Resolves a raw bech32-encoded LNURL (lud06) to an LNURL Pay Response.
    /// The bech32 string decodes to a plain UTF-8 HTTPS URL which is then fetched directly.
    static func resolveRawLNURL(_ lnurl: String) async throws -> LNURLPayResponse {
        // Strip scheme prefix if present (we add "lnurl:" as a sentinel internally)
        let raw = lnurl.lowercased().hasPrefix("lnurl:") ? String(lnurl.dropFirst(6)) : lnurl
        
        // bech32 decode — HRP is "lnurl", data is the UTF-8 encoded URL bytes
        guard let decoded = Bech32.decode(raw),
              let urlString = String(data: decoded.data, encoding: .utf8),
              let url = URL(string: urlString) else {
            RelayProcessManager.shared.addLog("LNURL: Failed to decode lud06 bech32: \(raw.prefix(20))…", level: "ERROR")
            throw LNURLError.invalidAddress
        }
        
        RelayProcessManager.shared.addLog("LNURL: Resolved lud06 to \(url.absoluteString)", level: "DEBUG")
        return try await fetchPayResponse(from: url)
    }

    /// Shared HTTP fetch + decode for any LNURL pay endpoint URL.
    private static func fetchPayResponse(from url: URL) async throws -> LNURLPayResponse {
        RelayProcessManager.shared.addLog("LNURL: Resolving \(url.absoluteString)", level: "DEBUG")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        
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
    static func fetchInvoice(callback: String, amountMsat: Int, zapRequest: NostrEvent?, comment: String? = nil) async throws -> String {
        guard var urlComponents = URLComponents(string: callback) else {
            throw LNURLError.invalidResponse
        }
        
        var queryItems = urlComponents.queryItems ?? []
        queryItems.append(URLQueryItem(name: "amount", value: String(amountMsat)))
        if let comment, !comment.isEmpty {
            queryItems.append(URLQueryItem(name: "comment", value: comment))
        }
        
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
        var invoiceRequest = URLRequest(url: url)
        invoiceRequest.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: invoiceRequest)
        
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

    // MARK: - Wallet send box: any LNURL, pay or withdraw

    /// LUD-03: a service that pays *you*.
    struct LNURLWithdrawResponse: Decodable {
        let callback: String
        let k1: String
        let minWithdrawable: Int
        let maxWithdrawable: Int
        let defaultDescription: String?
    }

    enum Resolved {
        case pay(LNURLPayResponse, host: String)
        case withdraw(LNURLWithdrawResponse, host: String)
    }

    /// The service's own error (`{"status":"ERROR","reason":…}`), shown as-is
    /// because it is usually the only useful explanation there is.
    struct ServiceError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Resolves whatever the user pasted — address, bech32 LNURL or LUD-17
    /// link — to the pay or withdraw request behind it.
    static func resolve(_ target: LightningPayTarget) async throws -> Resolved {
        let url: URL
        switch target {
        case .invoice:
            throw LNURLError.invalidAddress
        case .address(let lud16):
            let parts = lud16.components(separatedBy: "@")
            guard parts.count == 2,
                  let u = URL(string: "https://\(parts[1])/.well-known/lnurlp/\(parts[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parts[0])") else {
                throw LNURLError.invalidAddress
            }
            url = u
        case .lnurl(let bech32):
            guard let decoded = Bech32.decode(bech32),
                  let s = String(data: decoded.data, encoding: .utf8),
                  let u = URL(string: s) else { throw LNURLError.invalidAddress }
            url = u
        case .lnurlURL(let u):
            url = u
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LNURLError.networkError(error)
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let obj, (obj["status"] as? String)?.uppercased() == "ERROR" {
            throw ServiceError(reason: obj["reason"] as? String ?? "The service refused the request.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let obj else {
            throw LNURLError.invalidResponse
        }
        let host = url.host ?? ""
        switch obj["tag"] as? String {
        case "payRequest":
            return .pay(try JSONDecoder().decode(LNURLPayResponse.self, from: data), host: host)
        case "withdrawRequest":
            return .withdraw(try JSONDecoder().decode(LNURLWithdrawResponse.self, from: data), host: host)
        default:
            throw ServiceError(reason: "This link isn't a payment or a withdrawal, so the wallet can't use it.")
        }
    }

    /// LUD-03 step two: hand the service an invoice of ours to pay.
    static func submitWithdraw(_ w: LNURLWithdrawResponse, invoice: String) async throws {
        guard var comps = URLComponents(string: w.callback) else { throw LNURLError.invalidResponse }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "k1", value: w.k1))
        items.append(URLQueryItem(name: "pr", value: invoice))
        comps.queryItems = items
        guard let url = comps.url else { throw LNURLError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (obj?["status"] as? String)?.uppercased() == "OK" else {
            throw ServiceError(reason: obj?["reason"] as? String ?? "The service did not accept the withdrawal.")
        }
    }
}
