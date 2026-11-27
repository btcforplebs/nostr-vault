import Foundation

/// The built-in wallet's copy on the account's own Vault `/private` relay
/// (design RESEARCH/NV_CASHU_WALLET_DESIGN_2026_11_25.md §2, step A2; Logen's
/// pick (b): wallet events go to the owner's Vaults only, never public relays).
///
/// The local state file (`wallet.json`) is left out of iCloud and Time Machine
/// backups (Logen's pick, 2026-11-27): an old copy brought back from a backup
/// would hold proofs that were spent since, and the Vault is the truth anyway.
/// A new or restored device gets the wallet back from here instead. The Vault
/// database itself is still in backups, so a restored backup can bring old
/// 7375s back; that is safe because restore plus checkstate drops the spent
/// proofs, not because backups never hold them.
///
/// Pure over `CashuVaultIO`, so CashuWalletTests runs it against the real
/// engine and test mint with a stand-in Vault; `CashuVaultLink` is the app's IO.
enum CashuVaultSync {
    static let walletKind = 17375
    static let tokenKind = 7375
    static let quoteKind = 7374
    static let historyKind = 7376
    static let deletionKind = 5

    /// Kinds whose content is the wallet's secrets: never sent unless sealed.
    static let sealedKinds: Set<Int> = [walletKind, tokenKind, quoteKind, historyKind]

    // MARK: Restore on login

    /// Reads the account's wallet events from the Vault and merges them into
    /// this device's wallet (engine `restore`: merge by proof secret, then
    /// NUT-07 checkstate drops what another device spent).
    ///
    /// Fail-closed (§2 "never create a second 17375"): no wallet file is made
    /// unless the Vault answered and holds wallet events; a Vault that didn't
    /// answer is `cantReachVault`, never `noWallet`; a 17375 the signer can't
    /// open is `cantOpen`, and nothing is written. `noWallet` only says this
    /// Vault was empty when read: a new phone's own Vault is empty until the
    /// mesh copy from a desktop lands, so it is never the last word on its own
    /// (`CashuNewWalletGate`).
    static func restore(accountHex: String, base: URL = CashuWalletService.defaultBase,
                        io: CashuVaultIO) async -> CashuRestoreOutcome {
        let me = accountHex.lowercased()
        guard let own = await io.query(CashuVaultFilter(kinds: [walletKind, tokenKind, quoteKind], authors: [me])),
              let deletions = await io.query(CashuVaultFilter(kinds: [deletionKind], authors: [me],
                                                              kTags: ["\(tokenKind)", "\(quoteKind)"]))
        else { return .cantReachVault }

        let mine = own.filter { $0.pubkey.lowercased() == me }
        let walletEvent = mine.filter { $0.kind == walletKind }
            .max { ($0.created_at, $0.id) < ($1.created_at, $1.id) }
        let tokens = mine.filter { $0.kind == tokenKind }
        let quotes = mine.filter { $0.kind == quoteKind }
        let hadFile = CashuWalletService.exists(accountHex: me, base: base)
        if walletEvent == nil, tokens.isEmpty, quotes.isEmpty, !hadFile { return .noWallet }

        var input = CashuRestoreInput(account: me, deletions: deletions.filter { $0.pubkey.lowercased() == me })
        if let walletEvent {
            // The 17375 holds the wallet key: one we can't open stops here.
            guard let plain = try? await io.decryptFromSelf(walletEvent.content) else {
                return .cantOpen("Your signer couldn't open the wallet on your Vault.")
            }
            input.wallet = CashuOwnEvent(event: walletEvent, plaintext: plain)
        }
        var unopened = 0
        for event in tokens {
            if let plain = try? await io.decryptFromSelf(event.content) {
                input.tokens.append(CashuOwnEvent(event: event, plaintext: plain))
            } else {
                unopened += 1 // left out; merging less never loses a proof
            }
        }
        for event in quotes {
            if let plain = try? await io.decryptFromSelf(event.content) {
                input.quotes.append(CashuOwnEvent(event: event, plaintext: plain))
            } else {
                unopened += 1
            }
        }

        do {
            let wallet = try CashuWalletService.wallet(accountHex: me, create: true, base: base)
            var report = try await wallet.call("restore", CashuRestoreArgs(restore: input), as: CashuRestoreReport.self)
            report.unopened = unopened
            return .restored(report)
        } catch let error as CashuError where error.code == "key_conflict" {
            return .keyConflict
        } catch let error as CashuError where error.code == "bad_event" {
            // The engine holds the wallet (WalletHold): no new 17375 goes out
            // until a later restore opens the Vault's one.
            return .cantOpen("The wallet on your Vault can't be read.")
        } catch {
            return .failed((error as? CashuError)?.code ?? "error")
        }
    }

    // MARK: Publish after a change

    /// Brings the Vault copy up to date (engine `rollover`): each planned
    /// event is sealed to self when it holds secrets, signed by the account,
    /// sent to the Vault, and only then committed. Stops at the first failure;
    /// what is left goes out on the next call. Rounds repeat until the plan is
    /// empty (kind-5s for replaced 7375s come one round after them).
    static func publish(_ wallet: CashuWalletService, io: CashuVaultIO, maxRounds: Int = 6) async -> CashuPublishResult {
        var result = CashuPublishResult()
        for _ in 0..<maxRounds {
            let plan: [String: Any]
            do {
                plan = try JSONSerialization.jsonObject(with: try await wallet.callRaw("rollover")) as? [String: Any] ?? [:]
            } catch {
                result.failure = "rollover"
                return result
            }
            result.walletHold = plan["wallet_hold"] as? String
            let templates = plan["events"] as? [[String: Any]] ?? []
            if templates.isEmpty { return result }
            for template in templates {
                switch await publishOne(template, wallet: wallet, io: io) {
                case .sent(let id):
                    result.published.append(id)
                case .skipped:
                    result.skipped += 1
                case .failed(let why):
                    result.failure = why
                    return result
                }
            }
        }
        return result
    }

    private enum One { case sent(String), skipped, failed(String) }

    private static func publishOne(_ template: [String: Any], wallet: CashuWalletService, io: CashuVaultIO) async -> One {
        guard let kind = (template["kind"] as? NSNumber)?.intValue,
              let plain = template["content"] as? String else { return .failed("template") }
        // Rollover only plans /private events; anything else isn't ours to send here.
        guard template["where"] as? String == "private" else { return .skipped }
        let encrypt = template["encrypt"] as? Bool ?? false
        if sealedKinds.contains(kind), !encrypt { return .failed("unsealed") }
        let tags = (template["tags"] as? [[String]]) ?? []
        let createdAt = (template["created_at"] as? NSNumber)?.int64Value ?? 0
        var content = plain
        if encrypt {
            // NIP-44 is base64: never JSON. Anything else is plaintext.
            guard let sealed = try? await io.encryptToSelf(plain), !sealed.isEmpty, sealed != plain,
                  !sealed.hasPrefix("["), !sealed.hasPrefix("{") else { return .failed("encrypt") }
            content = sealed
        }
        guard let event = await io.sign(kind, createdAt, tags, content),
              event.pubkey.lowercased() == wallet.accountHex, event.kind == kind, event.content == content
        else { return .failed("sign") }
        guard await io.publish(event) else { return .failed("vault") }
        do {
            let args = try JSONSerialization.data(withJSONObject: ["template": template, "event_id": event.id])
            _ = try await wallet.callRaw("commit_published", args: args)
        } catch {
            return .failed("commit")
        }
        return .sent(event.id)
    }

    // MARK: Vault copies (§4 risk 4)

    /// Whether the Vault holds the account's 17375 now (read back after a
    /// publish). nil when it didn't answer.
    static func vaultHoldsWallet(accountHex: String, io: CashuVaultIO) async -> Bool? {
        let me = accountHex.lowercased()
        guard let found = await io.query(CashuVaultFilter(kinds: [walletKind], authors: [me])) else { return nil }
        return found.contains { $0.pubkey.lowercased() == me && $0.kind == walletKind }
    }
}

// MARK: - IO

/// A signed Nostr event, the same JSON as the app's `NostrEvent`.
struct CashuSignedEvent: Codable, Equatable, Sendable {
    var id: String
    var pubkey: String
    var created_at: Int64
    var kind: Int
    var tags: [[String]]
    var content: String
    var sig: String
}

/// One REQ filter on the Vault `/private` relay.
struct CashuVaultFilter: Equatable, Sendable {
    var kinds: [Int]
    var authors: [String]
    var kTags: [String]? = nil

    var json: [String: Any] {
        var f: [String: Any] = ["kinds": kinds, "authors": authors]
        if let kTags { f["#k"] = kTags }
        return f
    }

    func matches(_ e: CashuSignedEvent) -> Bool {
        guard kinds.contains(e.kind), authors.contains(e.pubkey.lowercased()) else { return false }
        guard let kTags else { return true }
        return e.tags.contains { $0.count > 1 && $0[0] == "k" && kTags.contains($0[1]) }
    }
}

/// What the sync needs from the outside: the account's own Vault and signer.
/// Every call is for one account; the app's IO refuses once another account
/// is active.
struct CashuVaultIO: Sendable {
    /// Every matching event on the Vault, or nil when it didn't answer.
    var query: @Sendable (CashuVaultFilter) async -> [CashuSignedEvent]?
    /// True only when the Vault took the event (OK true).
    var publish: @Sendable (CashuSignedEvent) async -> Bool
    var encryptToSelf: @Sendable (String) async throws -> String
    var decryptFromSelf: @Sendable (String) async throws -> String
    /// Signs kind/created_at (a floor)/tags/content as the account; nil on refusal.
    var sign: @Sendable (_ kind: Int, _ createdAt: Int64, _ tags: [[String]], _ content: String) async -> CashuSignedEvent?
}

enum CashuRestoreOutcome: Equatable {
    /// The Vault copy was merged in (the wallet is on this device now).
    case restored(CashuRestoreReport)
    /// The Vault answered and holds no wallet (yet); nothing was created.
    /// Read again later: a mesh copy may still bring it.
    case noWallet
    /// Not "no wallet": try again once the Vault answers.
    case cantReachVault
    /// "Wallet found but can't be opened": never replaced by a new one.
    case cantOpen(String)
    /// The Vault's wallet key differs from this device's; nothing replaced.
    case keyConflict
    case failed(String)

    /// A read that settles nothing for this launch: read the Vault again on
    /// the next relay start, account switch or finished mesh copy.
    var readAgain: Bool {
        switch self {
        case .restored(let report): return report.unopened > 0
        case .noWallet, .cantReachVault, .cantOpen, .keyConflict, .failed: return true
        }
    }
}

/// The engine's RestoreReport (haven-go/wallet/nip60_restore.go), plus the
/// events this signer couldn't open.
struct CashuRestoreReport: Codable, Equatable {
    var walletFound: Bool
    var mints: [String]?
    var added: UInt64
    var deleted: Int
    var bad: [String]?
    var quotes: Int
    var unopened: Int = 0

    enum CodingKeys: String, CodingKey {
        case mints, added, deleted, bad, quotes
        case walletFound = "wallet_found"
    }
}

struct CashuPublishResult: Equatable {
    var published: [String] = []
    var skipped = 0
    /// Where it stopped: rollover, template, unsealed, encrypt, sign, vault, commit.
    var failure: String?
    var walletHold: String?
    var ok: Bool { failure == nil }
}

struct CashuOwnEvent: Encodable {
    let event: CashuSignedEvent
    let plaintext: String
}

struct CashuRestoreInput: Encodable {
    let account: String
    var wallet: CashuOwnEvent?
    var tokens: [CashuOwnEvent] = []
    var quotes: [CashuOwnEvent] = []
    var deletions: [CashuSignedEvent]

    init(account: String, deletions: [CashuSignedEvent]) {
        self.account = account
        self.deletions = deletions
    }
}

private struct CashuRestoreArgs: Encodable {
    let restore: CashuRestoreInput
}
