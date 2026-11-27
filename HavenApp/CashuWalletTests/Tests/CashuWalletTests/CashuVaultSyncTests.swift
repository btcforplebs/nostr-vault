import XCTest
@testable import CashuWallet

/// A2: the wallet goes to the Vault `/private` relay after each change and
/// comes back from it on a device with no wallet.json (wallet.json is left out
/// of backups, so a restored or new phone has none). Real engine, real test
/// mint; events are really signed and NIP-44-sealed by a throwaway key (the
/// harness's /sign and /nip44); the Vault is an in-memory stand-in that keeps
/// what khatru keeps.
final class CashuVaultSyncTests: XCTestCase {
    struct Harness: Decodable { let mint: String; let control: String }
    struct Keypair: Decodable { let sk: String; let pk: String }

    private var harness: Harness!
    private var bases: [URL] = []

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CASHU_SWIFT_HARNESS"],
              let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("no test mint: run scripts/cashu-swift-test.sh")
        }
        harness = try JSONDecoder().decode(Harness.self, from: data)
    }

    override func tearDownWithError() throws {
        for base in bases { try? FileManager.default.removeItem(at: base) }
    }

    /// A device's own Application Support/Haven/cashu folder.
    private func newDevice() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cashu-a2-\(UUID().uuidString)")
        bases.append(root)
        return root.appendingPathComponent("Haven/cashu", isDirectory: true)
    }

    private func get(_ path: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: harness.control + path)!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200, path)
        return data
    }

    private static func post(_ url: String, _ body: [String: Any]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func newAccount() async throws -> Keypair {
        try JSONDecoder().decode(Keypair.self, from: try await get("/keypair"))
    }

    /// The app's IO for `account`, over `vault`.
    private func io(_ account: Keypair, _ vault: FakeVault) -> CashuVaultIO {
        let control = harness.control
        let sk = account.sk
        return CashuVaultIO(
            query: { await vault.query($0) },
            publish: { await vault.publish($0) },
            encryptToSelf: { text in
                let (d, code) = try await Self.post(control + "/nip44", ["sk": sk, "op": "encrypt", "text": text])
                guard code == 200 else { throw CashuError(code: "error", message: "encrypt") }
                return String(decoding: d, as: UTF8.self)
            },
            decryptFromSelf: { text in
                let (d, code) = try await Self.post(control + "/nip44", ["sk": sk, "op": "decrypt", "text": text])
                guard code == 200 else { throw CashuError(code: "error", message: "decrypt") }
                return String(decoding: d, as: UTF8.self)
            },
            sign: { kind, createdAt, tags, content in
                guard let (d, code) = try? await Self.post(control + "/sign",
                    ["sk": sk, "kind": kind, "created_at": max(createdAt, Int64(Date().timeIntervalSince1970)),
                     "tags": tags, "content": content]), code == 200 else { return nil }
                return try? JSONDecoder().decode(CashuSignedEvent.self, from: d)
            })
    }

    /// A wallet with a wallet key and `sats` minted at the test mint, on `base`.
    private func funded(_ account: Keypair, _ sats: UInt64, base: URL) async throws -> CashuWalletService {
        let w = try CashuWalletService.wallet(accountHex: account.pk, create: true, base: base)
        try await w.run("create_wallet_key")
        _ = try await w.addMint(harness.mint)
        let quote = try await w.requestMint(mint: harness.mint, amount: sats)
        _ = try await get("/pay?quote=\(quote.id)")
        _ = try await w.claimMint(quote: quote.id)
        return w
    }

    private func walletKey(_ w: CashuWalletService) async throws -> String {
        struct Key: Decodable { let has_key: Bool; let pubkey: String }
        let k = try await w.call("wallet_pubkey", as: Key.self)
        XCTAssertTrue(k.has_key)
        return k.pubkey
    }

    // MARK: Backups

    func testWalletFolderIsLeftOutOfBackups() async throws {
        let base = newDevice()
        let account = try await newAccount()
        let w = try await funded(account, 10, base: base)
        let folder = w.fileURL.deletingLastPathComponent()
        for var url in [folder, base] {
            url.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, url.path)
        }
        // The engine has replaced wallet.json (temp file + rename) several
        // times by now; the file sits in an excluded folder either way.
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.fileURL.path))
    }

    // MARK: Restore brings the wallet back

    func testRestoreOnANewDeviceBringsTheWalletBack() async throws {
        let account = try await newAccount()
        let vault = FakeVault()
        let phone = newDevice()
        let w = try await funded(account, 100, base: phone)

        let first = await CashuVaultSync.publish(w, io: io(account, vault))
        XCTAssertTrue(first.ok, "\(first)")
        let held = await vault.kinds()
        XCTAssertEqual(held[CashuVaultSync.walletKind], 1)
        XCTAssertEqual(held[CashuVaultSync.tokenKind], 1)
        let holds = await CashuVaultSync.vaultHoldsWallet(accountHex: account.pk, io: io(account, vault))
        XCTAssertEqual(holds, true)
        // Nothing in the Vault is readable without the account key.
        for event in await vault.all() where CashuVaultSync.sealedKinds.contains(event.kind) {
            XCTAssertFalse(event.content.contains("privkey") || event.content.contains("proofs") || event.content.contains(harness.mint))
        }

        // Spend, publish again: a new 7375 and a kind 5 for the old one.
        let invoice = String(decoding: try await get("/invoice?amount=30"), as: UTF8.self)
        _ = try await w.payInvoice(bolt11: invoice)
        let second = await CashuVaultSync.publish(w, io: io(account, vault))
        XCTAssertTrue(second.ok, "\(second)")
        let again = await CashuVaultSync.publish(w, io: io(account, vault))
        XCTAssertEqual(again.published, [], "a second publish with no change sends nothing")
        let before = try await w.balance()
        XCTAssertEqual(before.total, 69)
        let key = try await walletKey(w)

        // The restored phone: no wallet.json (left out of the backup).
        let restored = newDevice()
        XCTAssertFalse(CashuWalletService.exists(accountHex: account.pk, base: restored))
        let outcome = await CashuVaultSync.restore(accountHex: account.pk, base: restored, io: io(account, vault))
        guard case .restored(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(report.walletFound)
        XCTAssertEqual(report.unopened, 0)
        XCTAssertEqual(report.mints, [harness.mint])

        let back = try CashuWalletService.wallet(accountHex: account.pk, base: restored)
        let balance = try await back.balance()
        XCTAssertEqual(balance.total, 69, "the restored wallet has the same sats")
        XCTAssertEqual(balance.perMint?[harness.mint], 69)
        let backKey = try await walletKey(back)
        XCTAssertEqual(backKey, key, "same wallet key, so nutzaps still reach it")

        // And the sats are real: the restored wallet pays.
        let next = String(decoding: try await get("/invoice?amount=20"), as: UTF8.self)
        let paid = try await back.payInvoice(bolt11: next)
        XCTAssertGreaterThanOrEqual(paid.spent, 20)
        let after = await CashuVaultSync.publish(back, io: io(account, vault))
        XCTAssertTrue(after.ok, "\(after)")
        // Restore made no second wallet event.
        let walletEvents = await vault.kinds()
        XCTAssertEqual(walletEvents[CashuVaultSync.walletKind], 1)
    }

    /// The old phone still has its stale wallet.json: a restore there drops
    /// what the new one spent (checkstate), so it can't pay twice.
    func testStaleDeviceLearnsWhatTheOtherSpent() async throws {
        let account = try await newAccount()
        let vault = FakeVault()
        let old = try await funded(account, 100, base: newDevice())
        let pubOld = await CashuVaultSync.publish(old, io: io(account, vault))
        XCTAssertTrue(pubOld.ok, "\(pubOld)")

        let newBase = newDevice()
        guard case .restored = await CashuVaultSync.restore(accountHex: account.pk, base: newBase, io: io(account, vault))
        else { return XCTFail("no restore") }
        let new = try CashuWalletService.wallet(accountHex: account.pk, base: newBase)
        let invoice = String(decoding: try await get("/invoice?amount=50"), as: UTF8.self)
        _ = try await new.payInvoice(bolt11: invoice)
        let pubNew = await CashuVaultSync.publish(new, io: io(account, vault))
        XCTAssertTrue(pubNew.ok, "\(pubNew)")
        let newBalance = try await new.balance().total

        guard case .restored = await CashuVaultSync.restore(accountHex: account.pk, base: old.fileURL.deletingLastPathComponent().deletingLastPathComponent(), io: io(account, vault))
        else { return XCTFail("no restore on the old device") }
        let oldBalance = try await old.balance().total
        XCTAssertEqual(oldBalance, newBalance, "the old device no longer counts spent proofs")
    }

    // MARK: Fail closed

    func testEmptyVaultMakesNoWallet() async throws {
        let account = try await newAccount()
        let base = newDevice()
        let outcome = await CashuVaultSync.restore(accountHex: account.pk, base: base, io: io(account, FakeVault()))
        XCTAssertEqual(outcome, .noWallet)
        XCTAssertTrue(outcome.allowsNewWallet)
        XCTAssertFalse(CashuWalletService.exists(accountHex: account.pk, base: base))
    }

    func testUnreachableVaultIsNotNoWallet() async throws {
        let account = try await newAccount()
        let base = newDevice()
        let vault = FakeVault()
        await vault.setReachable(false)
        let outcome = await CashuVaultSync.restore(accountHex: account.pk, base: base, io: io(account, vault))
        XCTAssertEqual(outcome, .cantReachVault)
        XCTAssertFalse(outcome.allowsNewWallet)
        XCTAssertFalse(CashuWalletService.exists(accountHex: account.pk, base: base))
    }

    func testWalletTheSignerCantOpenIsNeverReplaced() async throws {
        let account = try await newAccount()
        let vault = FakeVault()
        let w = try await funded(account, 40, base: newDevice())
        let pubW = await CashuVaultSync.publish(w, io: io(account, vault))
        XCTAssertTrue(pubW.ok, "\(pubW)")

        var broken = io(account, vault)
        broken.decryptFromSelf = { _ in throw CashuError(code: "error", message: "signer said no") }
        let base = newDevice()
        let outcome = await CashuVaultSync.restore(accountHex: account.pk, base: base, io: broken)
        guard case .cantOpen = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(outcome.allowsNewWallet)
        XCTAssertFalse(CashuWalletService.exists(accountHex: account.pk, base: base), "nothing written")
    }

    func testAFailedSendIsRetriedNotLost() async throws {
        let account = try await newAccount()
        let vault = FakeVault()
        let w = try await funded(account, 60, base: newDevice())
        await vault.setRefusing(true)
        let failed = await CashuVaultSync.publish(w, io: io(account, vault))
        XCTAssertEqual(failed.failure, "vault")
        await vault.setRefusing(false)
        let retried = await CashuVaultSync.publish(w, io: io(account, vault))
        XCTAssertTrue(retried.ok, "\(retried)")
        let base = newDevice()
        guard case .restored = await CashuVaultSync.restore(accountHex: account.pk, base: base, io: io(account, vault))
        else { return XCTFail("no restore") }
        let back = try CashuWalletService.wallet(accountHex: account.pk, base: base)
        let total = try await back.balance().total
        XCTAssertEqual(total, 60)
    }

    func testUnsealedSecretsAreNeverSent() async throws {
        let account = try await newAccount()
        let vault = FakeVault()
        let w = try await funded(account, 10, base: newDevice())
        var leaky = io(account, vault)
        leaky.encryptToSelf = { $0 } // a signer that hands the plaintext back
        let result = await CashuVaultSync.publish(w, io: leaky)
        XCTAssertEqual(result.failure, "encrypt")
        let none = await vault.all()
        XCTAssertTrue(none.isEmpty)
    }
}

/// The account's Vault /private relay as khatru keeps it: the newest 17375
/// only, and a kind 5 by the author removes the events it names.
actor FakeVault {
    private var events: [CashuSignedEvent] = []
    private var reachable = true
    private var refusing = false

    func setReachable(_ on: Bool) { reachable = on }
    func setRefusing(_ on: Bool) { refusing = on }
    func all() -> [CashuSignedEvent] { events }

    func kinds() -> [Int: Int] {
        events.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    func query(_ filter: CashuVaultFilter) -> [CashuSignedEvent]? {
        guard reachable else { return nil }
        return events.filter(filter.matches)
    }

    func publish(_ event: CashuSignedEvent) -> Bool {
        guard reachable, !refusing else { return false }
        if event.kind == CashuVaultSync.walletKind {
            events.removeAll { $0.kind == event.kind && $0.pubkey == event.pubkey }
        }
        if event.kind == CashuVaultSync.deletionKind {
            let gone = Set(event.tags.filter { $0.count > 1 && $0[0] == "e" }.map { $0[1] })
            events.removeAll { gone.contains($0.id) && $0.pubkey == event.pubkey }
        }
        events.append(event)
        return true
    }
}
