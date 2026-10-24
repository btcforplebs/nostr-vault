import XCTest
@testable import MediaLogic

/// Edit Profile on a phone with several accounts put one account's kind 0 over
/// another's (2026-10-24): the save looked up and signed as whichever account
/// was active when it finished, not the one the form was opened for. A kind 0
/// goes out only when the form, the active account and the signature all name
/// the profile being edited.
final class ProfileSaveGuardTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let second = String(repeating: "b", count: 64)

    func testSameAccountMaySign() {
        XCTAssertTrue(ProfileSaveGuard.maySign(profilePubkey: second, formLoadedFor: second, activePubkey: second))
    }

    /// The incident: the second account's form, the owner active at save.
    func testAnotherActiveAccountMayNotSign() {
        XCTAssertFalse(ProfileSaveGuard.maySign(profilePubkey: second, formLoadedFor: second, activePubkey: owner))
    }

    func testFormLoadedFromAnotherAccountMayNotSign() {
        XCTAssertFalse(ProfileSaveGuard.maySign(profilePubkey: second, formLoadedFor: owner, activePubkey: second))
    }

    func testEmptyPubkeyMayNotSign() {
        XCTAssertFalse(ProfileSaveGuard.maySign(profilePubkey: "", formLoadedFor: "", activePubkey: ""))
    }

    func testOwnSignatureMayPublish() {
        XCTAssertTrue(ProfileSaveGuard.mayPublish(kind: 0, signedPubkey: second, profilePubkey: second, formLoadedFor: second))
        XCTAssertTrue(ProfileSaveGuard.mayPublish(kind: 0, signedPubkey: second.uppercased(), profilePubkey: second, formLoadedFor: second))
    }

    /// Signed by the owner's key while editing the second account: this is
    /// the event that wiped the owner's profile.
    func testOtherKeysSignatureMayNotPublish() {
        XCTAssertFalse(ProfileSaveGuard.mayPublish(kind: 0, signedPubkey: owner, profilePubkey: second, formLoadedFor: second))
    }

    func testFormFromAnotherAccountMayNotPublish() {
        XCTAssertFalse(ProfileSaveGuard.mayPublish(kind: 0, signedPubkey: second, profilePubkey: second, formLoadedFor: owner))
    }

    func testOnlyKindZero() {
        XCTAssertFalse(ProfileSaveGuard.mayPublish(kind: 1, signedPubkey: second, profilePubkey: second, formLoadedFor: second))
    }

    // MARK: - Wiring (ProfileEditView pulls in the whole app; read its source)

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func publishBody() throws -> String {
        let src = try source("HavenApp/Views/Profile/ProfileEditView.swift")
        let start = try XCTUnwrap(src.range(of: "static func publish("))
        let rest = src[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n")).lowerBound
        return String(rest[..<end])
    }

    /// Publishing reads the edited profile's pubkey, checks the guard right
    /// before signing, and checks the signed event before posting it.
    func testPublishIsGuarded() throws {
        let body = try publishBody()
        XCTAssertTrue(body.contains("let pubkey = existing.pubkey"))
        XCTAssertFalse(body.contains("let pubkey = nostrService.activeHexPubkey"))
        let sign = try XCTUnwrap(body.range(of: "signEventAsync(kind: 0"))
        let post = try XCTUnwrap(body.range(of: "postEvent(signed"))
        let lastMaySign = try XCTUnwrap(body.range(of: "ProfileSaveGuard.maySign(", options: .backwards))
        let mayPublish = try XCTUnwrap(body.range(of: "ProfileSaveGuard.mayPublish("))
        let lookup = try XCTUnwrap(body.range(of: "lookupNewestReplaceable"))
        XCTAssertTrue(lookup.upperBound < lastMaySign.lowerBound, "guard must run again after the relay wait")
        XCTAssertTrue(lastMaySign.upperBound < sign.lowerBound)
        XCTAssertTrue(sign.upperBound < mayPublish.lowerBound)
        XCTAssertTrue(mayPublish.upperBound < post.lowerBound)
    }

    /// Every place the iOS and Mac apps sign a kind 0, and each checks the
    /// signed pubkey before posting. A new kind-0 signer fails here until it
    /// is guarded and added to the list.
    func testEveryKindZeroSignerIsGuarded() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let signsKindZero = try NSRegularExpression(pattern: #"[sS]ign\w*\(kind: *0\b"#)
        var signers: [String] = []
        for dir in ["HavenApp", "HavenApp-iOS", "SilentPaymentsKit", "NostrVaultShare", "NostrVaultWidgets"] {
            let base = root.appendingPathComponent(dir)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let src = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(src.startIndex..., in: src)
                guard signsKindZero.firstMatch(in: src, range: range) != nil else { continue }
                signers.append(String(url.path.dropFirst(root.path.count + 1)))
                XCTAssertTrue(src.contains("ProfileSaveGuard.mayPublish("), "\(url.lastPathComponent) signs a kind 0 unguarded")
            }
        }
        XCTAssertEqual(signers.sorted(), [
            "HavenApp/Views/Profile/ProfileEditView.swift",
            "HavenApp/Views/SetupWizard/SetupWizardView.swift",
        ])
    }

    /// A new account's profile and relay list are signed as the new key by
    /// name, never as whichever account is active when the upload finishes.
    func testNewAccountSignsAsItsOwnKey() throws {
        let src = try source("HavenApp/Views/SetupWizard/SetupWizardView.swift")
        XCTAssertTrue(src.contains("signEventAsync(kind: 0, content: content, tags: [], signAsNpub: ownerNpub)"))
        XCTAssertTrue(src.contains("signEventAsync(kind: 10002, content: \"\", tags: relayTags, signAsNpub: ownerNpub)"))
    }

    /// Only the Save button publishes: no swipe-down autosave on any platform.
    func testNoSwipeDownSave() throws {
        let edit = try source("HavenApp/Views/Profile/ProfileEditView.swift")
        let page = try source("HavenApp/Views/Profile/MyProfileView.swift")
        for src in [edit, page] {
            XCTAssertFalse(src.contains("onAutosave"))
            XCTAssertFalse(src.contains("autosaveProfile"))
            XCTAssertFalse(src.contains("Swipe down to save"))
        }
        XCTAssertFalse(edit.contains(".onDisappear"), "closing the sheet must never publish")
    }
}
