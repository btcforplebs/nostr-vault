import XCTest
@testable import MediaLogic

/// The accounts a copy brings over (contract §3.4): Tal's fixtures, read
/// from docs/fixtures/mesh-copy like the engine's own tests, and this app's
/// side of the ask (offered, never added unasked).
final class CopyAccountsTests: XCTestCase {
    private let owner = "npub1fsgzj6t7udv8zhf6zj32mkqhcjcpv52yph5qsdcl0qt94jgdckqs4yjc3w"
    private let other = "npub13evkv42fprxqfpqdp966kn2cwpjrk9jflp08yelkkue20g977wpsv6pcap"
    private let third = "npub1ks0t9yldwmqlr2k8jnm25gs92za45mp5rhwtkk0r0wlz9wg688zs99ny60"

    private func accounts(_ raw: Any?) -> [CopyAccounts.Account] {
        (raw as? [[String: Any]] ?? []).map { .init(npub: $0["npub"] as? String ?? "", name: $0["name"] as? String ?? "") }
    }

    private func hex(_ npub: String) -> String { MeshPairing.npubHex(npub) ?? "" }

    // MARK: Fixtures

    func testRefuseCasesMatchTheEngine() throws {
        let cases = try XCTUnwrap(MeshCopyV2Tests.fixture("accounts-refuse-cases")["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 15)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["file"], name))
            let got: String
            switch CopyAccounts.check(data) {
            case .success: got = ""
            case .failure(let why): got = why.rawValue
            }
            XCTAssertEqual(got, c["expect"] as? String, name)
        }
    }

    func testMergeAndSharesMatchTheEngine() throws {
        let fx = try MeshCopyV2Tests.fixture("accounts-merge-cases")
        for c in try XCTUnwrap(fx["merge"] as? [[String: Any]]) {
            XCTAssertEqual(CopyAccounts.merge(mine: accounts(c["mine"]), theirs: accounts(c["theirs"])),
                           accounts(c["expect"]), c["name"] as? String ?? "?")
        }
        for c in try XCTUnwrap(fx["shares"] as? [[String: Any]]) {
            XCTAssertEqual(CopyAccounts.shares(mine: Set(c["mine"] as? [String] ?? []), theirs: c["theirs"] as? [String] ?? []),
                           c["expect"] as? Bool, c["name"] as? String ?? "?")
        }
    }

    // MARK: The file this app writes

    func testOwnFileKeepsWhatACopyBroughtAndPassesTheCheck() throws {
        let existing = [CopyAccounts.Account(npub: owner, name: "Old"), .init(npub: other, name: "Other")]
        let next = CopyAccounts.ownFile(own: [.init(npub: owner, name: "Owner")], existing: existing)
        XCTAssertEqual(next, [.init(npub: owner, name: "Owner"), .init(npub: other, name: "Other")])
        // An own account with no name yet keeps the one in the file.
        XCTAssertEqual(CopyAccounts.ownFile(own: [.init(npub: owner)], existing: existing).first?.name, "Old")
        let data = try XCTUnwrap(CopyAccounts.fileData(next, updatedAt: 1_767_000_000))
        XCTAssertEqual(try CopyAccounts.check(data).get(), next)
    }

    /// Look-only accounts here are never listed, and an older entry for one
    /// is dropped; a brought-over account not own here stays (Tron, #1810).
    func testOwnFileListsOnlySigningAccounts() {
        let existing = [CopyAccounts.Account(npub: owner, name: "Owner"), .init(npub: other, name: "Watched"),
                        .init(npub: third, name: "Brought")]
        let next = CopyAccounts.ownFile(own: [.init(npub: owner, name: "Owner"), .init(npub: other, name: "Watched")],
                                        existing: existing, lookOnly: [hex(other)])
        XCTAssertEqual(next.map(\.npub), [owner, third])
    }

    /// The service hands ownFile the signing accounts, and every other own one as look-only.
    func testServiceWritesSigningAccountsOnly() throws {
        let text = try source("Services/Relay/CopyAccountsSync.swift")
        let own = try body(of: "private func ownAccounts() -> [CopyAccounts.Account] {", in: text, length: 200)
        XCTAssertTrue(own.contains("ConfigService.shared.signingAccountNpubs"))
        XCTAssertFalse(own.contains("allAccountNpubs"))
        let write = try body(of: "func writeOwn() {", in: text, length: 600)
        XCTAssertTrue(write.contains("lookOnly: ownHex.subtracting(signing)"))
    }

    func testFileDataNeverWritesAKey() {
        let nsec = "nsec19uqxr6xazkeed24thcl9gwl8e5alzdtma8enxekqkv3ux3m9ty3qqp49sa"
        XCTAssertNil(CopyAccounts.fileData([.init(npub: owner, name: nsec)], updatedAt: 1))
        XCTAssertNil(CopyAccounts.fileData([.init(npub: hex(owner))], updatedAt: 1))
    }

    // MARK: The ask

    func testOfferedIsWhatThisDeviceLacksAndWasNeverAsked() {
        let file = [CopyAccounts.Account(npub: owner), .init(npub: other, name: "Other"), .init(npub: third), .init(npub: other)]
        let got = CopyAccounts.offered(file: file, ownHex: [hex(owner)], settledHex: [hex(third)])
        XCTAssertEqual(got, [.init(npub: other, name: "Other")])
        XCTAssertEqual(CopyAccounts.offered(file: file, ownHex: [hex(owner)], settledHex: []).map(\.npub), [other, third])
        XCTAssertTrue(CopyAccounts.offered(file: file, ownHex: [hex(owner), hex(other), hex(third)], settledHex: []).isEmpty)
    }

    // MARK: Wiring (source checks)

    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("HavenApp")

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of fn: String, in text: String, length: Int = 1400) throws -> Substring {
        let r = try XCTUnwrap(text.range(of: fn), fn)
        return text[r.upperBound...].prefix(length)
    }

    /// Only the ticked accounts join, as watch-only accounts: no live add
    /// (AddAccountsC), no key, no signer, no stored credential. They get
    /// vault space through the whitelist file like any account
    /// (VaultWhitelistTests).
    func testAnswerAddsOnlyTheTickedWatchOnly() throws {
        let text = try source("Services/Relay/CopyAccountsSync.swift")
        let answer = try body(of: "func answer(ticked: [CopyAccounts.Account]) {", in: text)
        XCTAssertTrue(answer.contains("for a in chosen where"), "only the ticked ones")
        XCTAssertTrue(answer.contains("whitelistedNpubs.append(a.npub)"))
        for banned in ["AddAccountsC", "storeNsec", "Ncryptsec", "bunker", "Credential", "Keychain", "publish"] {
            XCTAssertFalse(answer.localizedCaseInsensitiveContains(banned), banned)
        }
        // Nothing in the app calls AddAccountsC any more.
        for path in ["Services/Relay/MeshCopyV2Service.swift", "Services/Relay/CopySettingsSync.swift",
                     "Services/Relay/CopyAccountsSync.swift", "Views/SetupWizard/BringItOverStep.swift",
                     "Views/Settings/AddAccountSheetView.swift"] {
            XCTAssertFalse(try source(path).contains("AddAccountsC("), path)
        }
    }

    /// The ask says what ticking gives (Logen, 2026-11-12): a place in this
    /// vault, npub only. It must never promise "no access" again.
    func testAskSaysTickedAccountsGetVaultSpace() throws {
        let view = try source("Views/SetupWizard/CopyAccountsAskView.swift")
        XCTAssertFalse(view.localizedCaseInsensitiveContains("no access"))
        XCTAssertTrue(view.contains("their own space in this vault"))
    }

    /// A finished copy refreshes the offer, and setup asks before it goes on.
    func testCopyDoneAsksBeforeSetupGoesOn() throws {
        let service = try source("Services/Relay/MeshCopyV2Service.swift")
        let handle = try body(of: "func handle(_ lines: [MeshCopyV2.Progress]) {", in: service, length: 900)
        XCTAssertTrue(handle.contains("CopyAccountsSync.shared.refreshOffer()"))
        let step = try source("Views/SetupWizard/BringItOverStep.swift")
        let done = try body(of: "private func done() {", in: step, length: 500)
        XCTAssertTrue(done.contains("accounts.refreshOffer()"))
        XCTAssertLessThan(try XCTUnwrap(done.range(of: "asking = true")).lowerBound,
                          try XCTUnwrap(done.range(of: "finished = true")).lowerBound)
        XCTAssertTrue(step.contains("CopyAccountsAskView(accounts: accounts.offered)"))
        let watch = try body(of: "private func watch() {", in: step, length: 300)
        XCTAssertTrue(watch.contains("guard !finished, !asking else { return }"), "an ask on screen is not a stalled copy")
    }
}
