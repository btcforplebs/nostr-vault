import Foundation

/// One account's built-in Cashu wallet (design
/// RESEARCH/NV_CASHU_WALLET_DESIGN_2026_11_25.md §2, step A1): a typed face on
/// the engine's JSON calls (`CashuBridge`). The engine keeps the proofs and the
/// journal in one state file per account, in the app's own Application
/// Support folder; publishing the NIP-60 events from it is step A2.
final class CashuWalletService: @unchecked Sendable {
    let accountHex: String
    let fileURL: URL
    private let handle: Int32

    private init(accountHex: String, fileURL: URL) throws {
        self.accountHex = accountHex
        self.fileURL = fileURL
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: Self.folderAttributes)
        Self.excludeFromBackup(fileURL.deletingLastPathComponent())
        handle = try CashuBridge.open(path: fileURL.path)
    }

    deinit { CashuBridge.close(handle) }

    // MARK: Where the wallets live

    /// `<base>/<account hex>/wallet.json`. `base` is Application Support/Haven/cashu.
    static func fileURL(accountHex: String, base: URL = defaultBase) -> URL {
        base.appendingPathComponent(accountHex.lowercased(), isDirectory: true).appendingPathComponent("wallet.json")
    }

    static var defaultBase: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Haven", isDirectory: true).appendingPathComponent("cashu", isDirectory: true)
    }

    /// True once this account has a wallet on this device. Never creates one.
    static func exists(accountHex: String, base: URL = defaultBase) -> Bool {
        isAccountHex(accountHex) && FileManager.default.fileExists(atPath: fileURL(accountHex: accountHex, base: base).path)
    }

    /// wallet.json stays out of iCloud, Finder and Time Machine backups
    /// (Logen's pick, 2026-11-27): an old copy brought back would count
    /// proofs spent since. The Vault copy brings the wallet back instead
    /// (`CashuVaultSync.restore`). The flag is on the folders, not the file:
    /// the engine replaces wallet.json by renaming a temp file into place,
    /// which would drop a flag set on the file itself.
    static func excludeFromBackup(_ folder: URL) {
        for var url in [folder, folder.deletingLastPathComponent()] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    private static let lock = NSLock()
    private static var open: [String: CashuWalletService] = [:]

    /// The account's wallet, opened once per process. `create` false (paying)
    /// refuses an account with no wallet file yet, so a payment never makes
    /// an empty wallet; screens that set one up (A3) pass true.
    static func wallet(accountHex: String, create: Bool = false, base: URL = defaultBase) throws -> CashuWalletService {
        let hex = accountHex.lowercased()
        guard isAccountHex(hex) else { throw CashuError.noWallet }
        let url = fileURL(accountHex: hex, base: base)
        lock.lock(); defer { lock.unlock() }
        if let w = open[url.path] { return w }
        guard create || FileManager.default.fileExists(atPath: url.path) else { throw CashuError.noWallet }
        let w = try CashuWalletService(accountHex: hex, fileURL: url)
        open[url.path] = w
        return w
    }

    private static func isAccountHex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy(\.isHexDigit)
    }

    #if os(iOS)
    private static let folderAttributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
    private static let folderAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #endif

    // MARK: Engine calls

    struct NoArgs: Encodable {}

    /// One engine call, off the main thread (mint calls block up to 2 min).
    func call<Result: Decodable>(_ method: String, _ args: some Encodable = NoArgs(), as type: Result.Type) async throws -> Result {
        let body = try JSONEncoder().encode(args)
        let handle = handle
        let data = try await Task.detached(priority: .userInitiated) {
            try CashuBridge.call(handle, method, args: body)
        }.value
        return try JSONDecoder().decode(Result.self, from: data)
    }

    /// A call with JSON in and out as they are (rollover templates must go
    /// back to commit_published unchanged, meta included).
    func callRaw(_ method: String, args: Data? = nil) async throws -> Data {
        let handle = handle
        return try await Task.detached(priority: .userInitiated) {
            try CashuBridge.call(handle, method, args: args)
        }.value
    }

    /// A call whose result we don't read.
    func run(_ method: String, _ args: some Encodable = NoArgs()) async throws {
        _ = try await call(method, args, as: CashuIgnored.self)
    }

    func balance() async throws -> CashuBalance { try await call("balance", as: CashuBalance.self) }
    func mints() async throws -> [String] { try await call("mints", as: [String]?.self) ?? [] }

    func addMint(_ url: String) async throws -> CashuMintSummary {
        try await call("add_mint", ["mint": url], as: CashuMintSummary.self)
    }

    /// A Lightning invoice that mints `amount` sats at `mint` once paid.
    func requestMint(mint: String, amount: UInt64) async throws -> CashuMintQuote {
        try await call("request_mint", CashuAmountArgs(mint: mint, amount: amount), as: CashuMintQuote.self)
    }

    /// Mints a paid quote's proofs; the amount minted. `not_paid` until it is.
    func claimMint(quote: String) async throws -> UInt64 {
        try await call("claim_mint", ["quote": quote], as: UInt64.self)
    }

    func quoteMelt(mint: String, bolt11: String) async throws -> CashuMeltQuote {
        try await call("quote_melt", ["mint": mint, "bolt11": bolt11], as: CashuMeltQuote.self)
    }

    func melt(_ quote: CashuMeltQuote) async throws -> CashuMeltResult {
        try await call("melt", CashuMeltArgs(melt: quote), as: CashuMeltResult.self)
    }

    /// Spends the engine journaled but never heard back about (a melt in
    /// flight when the app died). Finishing them frees the mint for new spends.
    /// Stuck ops (the engine could not finish them, for example a paid melt
    /// whose change came back bad) are listed too: they stay forever and
    /// already hold their inputs out of the balance.
    func pending() async throws -> [CashuPendingOp] { try await call("pending", as: [CashuPendingOp]?.self) ?? [] }
    func pendingCount() async throws -> Int { try await pending().count }
    /// Ops whose answer from the mint is still unknown (not stuck): the same
    /// rule the engine's mintBusy uses. Only these may still move money.
    func unsettledCount() async throws -> Int { try await pending().filter(\.isUnsettled).count }
    func recover() async throws { try await run("recover") }

    // MARK: Paying an invoice

    /// Pays `bolt11` by melting at one mint (NUT-05). Mints are tried from the
    /// biggest balance down, and the next one only when this one refused
    /// before any money moved. `pending` (the mint may still pay) stops
    /// at once: paying the same invoice from a second mint could pay twice.
    func payInvoice(bolt11: String) async throws -> CashuMeltResult {
        // An earlier payment the mint hasn't settled may be this same invoice
        // (a retry after "may still pay"). Starting another one, at any mint,
        // could pay it twice, so nothing new goes out until recover clears it.
        // A stuck op doesn't count: its outcome is known (only the change is
        // missing), and counting it would block this wallet for good.
        if try await pendingCount() > 0 {
            try? await recover()
            if try await unsettledCount() > 0 { throw CashuError(code: "busy", message: "an earlier payment is still unsettled") }
        }
        let balance = try await balance()
        let order = Self.payOrder(balance)
        guard !order.isEmpty else { throw CashuError.notEnough }
        var first: Error?
        for (mint, have) in order {
            let quote: CashuMeltQuote
            do {
                quote = try await quoteMelt(mint: mint, bolt11: bolt11)
            } catch {
                first = first ?? error
                continue
            }
            guard quote.amount + quote.feeReserve <= have else {
                first = first ?? CashuError.notEnough
                continue
            }
            do {
                return try await melt(quote)
            } catch let error as CashuError where Self.triesNextMint(error.code) {
                first = first ?? error
            }
        }
        throw first ?? CashuError.notEnough
    }

    /// Mints with sats to spend, biggest first (ties by URL, so the order is fixed).
    static func payOrder(_ balance: CashuBalance) -> [(mint: String, sats: UInt64)] {
        (balance.perMint ?? [:]).filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (mint: $0.key, sats: $0.value) }
    }

    /// Refusals that happen before the engine journals the spend, so no
    /// money moved. Anything else stops the payment: pending, an error after
    /// the mint call, and busy (that mint's unfinished op may be this invoice).
    static func triesNextMint(_ code: String) -> Bool {
        ["not_enough", "no_change", "unknown_mint"].contains(code)
    }
}

// MARK: Engine shapes (haven-go/wallet: Balance, MintSummary, MintQuote, MeltQuote, MeltResult)

struct CashuBalance: Codable, Equatable {
    var total: UInt64
    var perMint: [String: UInt64]?
    var reserved: UInt64
    var inFlight: UInt64
    var warn: Bool

    enum CodingKeys: String, CodingKey {
        case total, reserved, warn
        case perMint = "per_mint"
        case inFlight = "in_flight"
    }
}

struct CashuMintSummary: Codable, Equatable {
    var url: String
    var name: String
    var checkstate: Bool
    var restore: Bool
    var p2pk: Bool
    var dleq: Bool
    var sat: Bool

    enum CodingKeys: String, CodingKey {
        case url, name, sat
        case checkstate = "nut07", restore = "nut09", p2pk = "nut11", dleq = "nut12"
    }
}

struct CashuMintQuote: Codable, Equatable {
    var id: String
    var mint: String
    var amount: UInt64
    var request: String
    var expiry: UInt64?
}

/// What paying an invoice costs at one mint. Handed back to `melt` as it is:
/// the engine re-reads it from the mint and refuses a changed quote.
struct CashuMeltQuote: Codable, Equatable {
    var id: String
    var mint: String
    var amount: UInt64
    var feeReserve: UInt64
    var expiry: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, mint, amount, expiry
        case feeReserve = "fee_reserve"
    }
}

struct CashuMeltResult: Codable, Equatable {
    var preimage: String?
    var spent: UInt64
    var change: UInt64
}

private struct CashuAmountArgs: Encodable {
    let mint: String
    let amount: UInt64
}

private struct CashuMeltArgs: Encodable {
    let melt: CashuMeltQuote
}

/// One journaled engine op (wallet.Op), only the fields the app reads.
struct CashuPendingOp: Decodable, Equatable {
    let id: String
    let kind: String?
    let mint: String?
    let stuck: String?
    var isUnsettled: Bool { (stuck ?? "").isEmpty }
}

/// Decodes any JSON value, keeping nothing.
struct CashuIgnored: Decodable {
    init(from decoder: Decoder) throws {}
}
