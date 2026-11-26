import Foundation
#if canImport(CHavenCashu)
import CHavenCashu // the CashuWalletTests package; the app gets these from libhaven.h
#endif

/// The built-in Cashu wallet's engine calls (haven-go/wallet/bridge.go,
/// exported by haven-go/cashu_wallet_cshared.go). Every reply is
/// `{"ok":true,"result":…}` or `{"ok":false,"error":"…","code":"…"}`.
/// Mint calls block for up to 2 minutes, so `call` must never run on the
/// main thread; `CashuWalletService` runs it detached.
enum CashuBridge {
    /// Opens the wallet whose state file is `path` (absolute). The same path
    /// gives the same handle; close once per open.
    static func open(path: String) throws -> Int32 {
        let raw = path.withCString { CashuWalletOpenC(UnsafeMutablePointer(mutating: $0)) }
        let result = try reply(take(raw))
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let handle = (object["handle"] as? NSNumber)?.int32Value, handle > 0
        else { throw CashuError(code: "error", message: "The wallet engine gave no handle.") }
        return handle
    }

    /// Runs `method` with `args` (a JSON object, or empty). Returns the
    /// result's JSON (`null` when the method has none). Blocks: off main only.
    static func call(_ handle: Int32, _ method: String, args: Data?) throws -> Data {
        let argText = args.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let raw = method.withCString { m in
            argText.withCString { a in
                CashuWalletCallC(handle, UnsafeMutablePointer(mutating: m), UnsafeMutablePointer(mutating: a))
            }
        }
        return try reply(take(raw))
    }

    static func close(_ handle: Int32) {
        CashuWalletCloseC(handle)
    }

    /// Copies and frees a C string the engine handed back.
    private static func take(_ raw: UnsafeMutablePointer<CChar>?) -> Data {
        guard let raw else { return Data() }
        defer { free(raw) }
        return Data(bytes: raw, count: strlen(raw))
    }

    /// The `result` of an ok reply as JSON, or the reply's error thrown as a
    /// `CashuError` with the engine's stable code.
    static func reply(_ data: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CashuError(code: "error", message: "The wallet engine gave an unreadable answer.")
        }
        guard object["ok"] as? Bool == true else {
            throw CashuError(code: object["code"] as? String ?? "error",
                             message: object["error"] as? String ?? "The wallet engine refused.")
        }
        guard let result = object["result"], !(result is NSNull) else { return Data("null".utf8) }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }
}

/// An engine refusal. `code` is the engine's stable name (`cashuErrCodes` in
/// haven-go/wallet/bridge.go); `message` is its own text, for logs.
struct CashuError: Error, LocalizedError, Equatable {
    let code: String
    let message: String

    static let noWallet = CashuError(code: "no_wallet", message: "No built-in wallet for this account.")
    static let notEnough = CashuError(code: "not_enough", message: "Not enough sats in the built-in wallet.")

    /// The mint may have paid or may still pay: wait for the receipt and
    /// never pay the same thing again from another mint. The engine kept the
    /// spend in its journal, so its recover finishes it either way.
    var mayStillSettle: Bool { code == "pending" }

    var errorDescription: String? {
        switch code {
        case "pending": return "Sent from your built-in wallet. The mint hasn't confirmed yet, so it may still pay."
        case "not_enough": return "Your built-in wallet doesn't have enough sats for this and the mint's fee."
        case "busy": return "Your built-in wallet is finishing an earlier payment. Try again in a moment."
        case "no_change": return "This mint can't give change, so paying from it would lose sats. Nothing was sent."
        case "unknown_mint": return "That mint isn't in your built-in wallet."
        case "no_wallet": return "There's no built-in wallet for this account on this device yet."
        default: return "Your built-in wallet couldn't pay: \(message)"
        }
    }
}
