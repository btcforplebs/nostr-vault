import XCTest
@testable import MediaLogic

/// NIP-94 file notes on the home vault's /files (RESEARCH plan §1-§2): the
/// tags a device signs, what a reader accepts, the live merge, and when a
/// tile hides.
final class FileNoteTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)
    private let other = String(repeating: "cd", count: 32)
    private let owner = String(repeating: "11", count: 32)
    private let phone = String(repeating: "22", count: 32)
    private let pad = String(repeating: "33", count: 32)

    private func note(id: String, signer: String? = nil, sha: String? = nil, at: Int64 = 100,
                      tags extra: [[String]] = [], owner: String? = nil, kind: Int = 1063) -> [String: Any] {
        var tags: [[String]] = [["x", sha ?? self.sha], ["m", "image/jpeg"], ["size", "38091"], ["p", owner ?? self.owner]]
        tags += extra
        return ["id": id, "pubkey": signer ?? phone, "created_at": at, "kind": kind, "tags": tags, "content": "", "sig": "s"]
    }

    private func deletion(id: String, of ids: [String], sha: String? = nil, at: Int64 = 200, signer: String? = nil) -> [String: Any] {
        var tags = ids.map { ["e", $0] }
        tags += [["k", "1063"], ["x", sha ?? self.sha], ["p", owner]]
        return ["id": id, "pubkey": signer ?? pad, "created_at": at, "kind": 5, "tags": tags, "content": "", "sig": "s"]
    }

    // MARK: Tags

    func testTagsNameTheBlobItsTypeSizeOwnerAndServers() throws {
        let tags = try XCTUnwrap(FileNote.tags(sha256: sha.uppercased(), mime: "image/jpeg", size: 38091, owner: owner,
                                               servers: ["https://nostr.build/", "https://blossom.band"]))
        XCTAssertEqual(tags, [
            ["x", sha], ["m", "image/jpeg"], ["size", "38091"], ["p", owner],
            ["url", "https://nostr.build/\(sha).jpg"],
            ["fallback", "https://blossom.band/\(sha).jpg"],
            ["client", "nostr-vault"],
        ])
    }

    func testTagsWithNoServerNameTheVaultOnly() throws {
        let tags = try XCTUnwrap(FileNote.tags(sha256: sha, mime: "video/mp4", size: 5, owner: owner, servers: []))
        XCTAssertFalse(tags.contains { $0.first == "url" || $0.first == "fallback" })
    }

    func testTagsLeaveOutMeshAndHomeNetworkServers() throws {
        let tags = try XCTUnwrap(FileNote.tags(sha256: sha, mime: "image/png", size: 5, owner: owner,
                                               servers: ["fipsmesh://npub1x/", "http://192.168.1.4:3355", "https://cdn.example.com"]))
        XCTAssertEqual(tags.filter { $0.first == "url" }, [["url", "https://cdn.example.com/\(sha).png"]])
        XCTAssertFalse(tags.contains { $0.first == "fallback" })
    }

    func testTagsRefuseABadHashTypeSizeOrOwner() {
        XCTAssertNil(FileNote.tags(sha256: "abc", mime: "image/png", size: 1, owner: owner, servers: []))
        XCTAssertNil(FileNote.tags(sha256: sha, mime: " ", size: 1, owner: owner, servers: []))
        XCTAssertNil(FileNote.tags(sha256: sha, mime: "image/png", size: -1, owner: owner, servers: []))
        XCTAssertNil(FileNote.tags(sha256: sha, mime: "image/png", size: 1, owner: "npub1notahex", servers: []))
    }

    func testDeletionTagsNameEveryNoteTheKindTheHashAndTheOwner() throws {
        let tags = try XCTUnwrap(FileNoteDeletion.tags(noteIDs: ["n2", "n1", "n2"], sha256: sha, owner: owner))
        XCTAssertEqual(tags, [["e", "n1"], ["e", "n2"], ["k", "1063"], ["x", sha], ["p", owner]])
        XCTAssertNil(FileNoteDeletion.tags(noteIDs: [], sha256: sha, owner: owner), "a kind 5 here must name notes")
    }

    // MARK: Parse

    func testParseReadsANote() throws {
        let n = try XCTUnwrap(FileNote.parse(note(id: "n1", tags: [["url", "https://a.example/\(sha).jpg"], ["fallback", "https://b.example/\(sha)"]])))
        XCTAssertEqual(n.id, "n1")
        XCTAssertEqual(n.signer, phone)
        XCTAssertEqual(n.sha256, sha)
        XCTAssertEqual(n.mime, "image/jpeg")
        XCTAssertEqual(n.size, 38091)
        XCTAssertEqual(n.owner, owner)
        XCTAssertEqual(n.urls, ["https://a.example/\(sha).jpg", "https://b.example/\(sha)"])
    }

    func testParseRefusesBadNotes() {
        XCTAssertNil(FileNote.parse(note(id: "n", sha: "ABAB")), "x must be 64 lower-case hex")
        XCTAssertNil(FileNote.parse(note(id: "n", sha: sha.uppercased())))
        XCTAssertNil(FileNote.parse(note(id: "n", kind: 1)))
        var noSize = note(id: "n")
        noSize["tags"] = [["x", sha], ["m", "image/jpeg"], ["p", owner]]
        XCTAssertNil(FileNote.parse(noSize))
        XCTAssertNil(FileNote.parse(note(id: "n", tags: [["p", pad]])), "one p tag only")
        XCTAssertNil(FileNote.parse(note(id: "", signer: phone)))
    }

    func testParseKeepsOnlyHttpsLinks() throws {
        let n = try XCTUnwrap(FileNote.parse(note(id: "n", tags: [["url", "javascript:alert(1)"], ["fallback", "http://x.example/a"], ["fallback", "https://ok.example/\(sha)"]])))
        XCTAssertEqual(n.urls, ["https://ok.example/\(sha)"])
    }

    func testParseDeletionNeedsKindTagAndNotes() throws {
        let d = try XCTUnwrap(FileNoteDeletion.parse(deletion(id: "d1", of: ["n1", "n2"])))
        XCTAssertEqual(d.noteIDs, ["n1", "n2"])
        var noK = deletion(id: "d2", of: ["n1"])
        noK["tags"] = [["e", "n1"], ["x", sha]]
        XCTAssertNil(FileNoteDeletion.parse(noK))
        XCTAssertNil(FileNoteDeletion.parse(deletion(id: "d3", of: [])))
    }

    // MARK: Live merge

    func testANoteForANewHashAddsATile() {
        var state = FileNotesState()
        XCTAssertEqual(state.apply(note(id: "n1")), .added(sha))
        XCTAssertEqual(state.tiles.map(\.sha256), [sha])
        XCTAssertEqual(state.apply(note(id: "n1")), .none, "the same note twice changes nothing")
    }

    func testASecondDeviceNoteForTheSameHashMergesLinks() {
        var state = FileNotesState()
        _ = state.apply(note(id: "n1", tags: [["url", "https://a.example/\(sha)"]]))
        XCTAssertEqual(state.apply(note(id: "n2", signer: pad, at: 150, tags: [["url", "https://b.example/\(sha)"]])), .none)
        XCTAssertEqual(state.tiles.count, 1)
        XCTAssertEqual(state.tiles[0].urls, ["https://b.example/\(sha)", "https://a.example/\(sha)"], "newest note's links first")
        XCTAssertEqual(Set(state.noteIDs(for: sha)), ["n1", "n2"])
    }

    func testTilesAreNewestFirst() {
        var state = FileNotesState()
        _ = state.apply(note(id: "n1", at: 100))
        _ = state.apply(note(id: "n2", sha: other, at: 300))
        XCTAssertEqual(state.tiles.map(\.sha256), [other, sha])
    }

    func testADeletionDropsTheTileOnlyWhenNoLiveNoteNamesTheHash() {
        var state = FileNotesState()
        _ = state.apply(note(id: "n1"))
        _ = state.apply(note(id: "n2", signer: pad))
        XCTAssertEqual(state.apply(deletion(id: "d1", of: ["n1"])), .none, "n2 still names it")
        XCTAssertEqual(state.tiles.map(\.sha256), [sha])
        XCTAssertEqual(state.apply(deletion(id: "d2", of: ["n2"])), .removed(sha))
        XCTAssertTrue(state.tiles.isEmpty)
    }

    func testADeletedNoteNeverComesBack() {
        var state = FileNotesState()
        _ = state.apply(deletion(id: "d1", of: ["n1"]))
        XCTAssertEqual(state.apply(note(id: "n1")), .none, "the deletion came first (replay order)")
        XCTAssertTrue(state.tiles.isEmpty)
        XCTAssertEqual(state.apply(note(id: "n3", at: 400)), .added(sha), "a re-upload is a new note and lands")
    }

    func testTheOwnerFilterKeepsOtherAccountsOut() {
        var state = FileNotesState(owner: owner)
        XCTAssertEqual(state.apply(note(id: "n1", owner: pad)), .none)
        XCTAssertTrue(state.tiles.isEmpty)
    }

    func testResubscribeSinceTheNewestSeenWithOverlap() {
        var state = FileNotesState()
        XCTAssertNil(state.since)
        _ = state.apply(note(id: "n1", at: 1_000))
        _ = state.apply(deletion(id: "d1", of: ["x"], at: 2_000))
        XCTAssertEqual(state.since, 2_000 - FileNotesState.resubscribeOverlap)
    }

    func testLiveFilterAsksForNotesAndDeletionsOfTheOwner() {
        XCTAssertEqual(FileNote.liveFilter(owner: owner, since: nil) as NSDictionary,
                       ["kinds": [1063, 5], "#p": [owner]] as NSDictionary)
        XCTAssertEqual(FileNote.liveFilter(owner: owner, since: 50) as NSDictionary,
                       ["kinds": [1063, 5], "#p": [owner], "since": 50] as NSDictionary)
    }

    // MARK: AUTH

    func testAuthNamesTheVaultsMeshAddressOverTheMesh() {
        let url = URL(string: "ws://127.0.0.1:41234/sometoken/files")!
        XCTAssertEqual(FileNote.authRelayURL(vaultNpub: "npub1vault", connected: url), "ws://npub1vault.fips/files")
    }

    func testAuthNamesTheLoopbackURLOnTheVaultItself() {
        let url = URL(string: "wss://127.0.0.1:3355/files")!
        XCTAssertEqual(FileNote.authRelayURL(vaultNpub: nil, connected: url), "wss://127.0.0.1:3355/files")
    }

    func testFilesURLKeepsTheIngressTokenPath() {
        let base = URL(string: "http://127.0.0.1:41234/tok")!
        XCTAssertEqual(FileNote.filesURL(base: base)?.absoluteString, "ws://127.0.0.1:41234/tok/files")
        XCTAssertEqual(FileNote.filesURL(base: URL(string: "https://127.0.0.1:3355")!)?.absoluteString, "wss://127.0.0.1:3355/files")
    }

    // MARK: Tile check (gap 3)

    func testATileHidesOnlyWhenEveryServerSays404AndTheVaultLacksIt() {
        XCTAssertEqual(FileNote.tileState(serverStatuses: [404, 404], vaultHas: false), .hidden)
        XCTAssertEqual(FileNote.tileState(serverStatuses: [404, 404], vaultHas: nil), .dimmed, "vault not asked: not proof")
        XCTAssertEqual(FileNote.tileState(serverStatuses: [404, nil], vaultHas: false), .dimmed, "unreachable is not gone")
        XCTAssertEqual(FileNote.tileState(serverStatuses: [404, 200], vaultHas: false), .visible)
        XCTAssertEqual(FileNote.tileState(serverStatuses: [], vaultHas: true), .visible)
        XCTAssertEqual(FileNote.tileState(serverStatuses: [], vaultHas: false), .hidden)
        XCTAssertEqual(FileNote.tileState(serverStatuses: [500], vaultHas: false), .dimmed)
    }
    // MARK: What the mesh key may sign for /files (the Swift twin of Android's fileNotesAllowed)

    func testTheMeshKeySignsOnlyFilesEvents() {
        XCTAssertTrue(FileNote.meshKeyMaySign(kind: 1063, tags: [["x", "a"]]))
        XCTAssertTrue(FileNote.meshKeyMaySign(kind: 5, tags: [["e", "id"], ["k", "1063"]]))
        XCTAssertFalse(FileNote.meshKeyMaySign(kind: 5, tags: [["e", "id"]]), "a kind 5 must say it is about notes")
        XCTAssertFalse(FileNote.meshKeyMaySign(kind: 5, tags: [["e", "id"], ["k", "1063"], ["k", "1"]]),
                       "never a kind 5 that also takes back a post")
        XCTAssertTrue(FileNote.meshKeyMaySign(kind: 22242, tags: [["relay", "ws://npub1v.fips/files"], ["challenge", "c"]]))
        XCTAssertTrue(FileNote.meshKeyMaySign(kind: 22242, tags: [["relay", "ws://127.0.0.1:4869/files/"], ["challenge", "c"]]))
        XCTAssertFalse(FileNote.meshKeyMaySign(kind: 22242, tags: [["relay", "wss://relay.example/"], ["challenge", "c"]]),
                       "AUTH for any other room is not the mesh key's to sign")
        XCTAssertFalse(FileNote.meshKeyMaySign(kind: 1, tags: []))
        XCTAssertFalse(FileNote.meshKeyMaySign(kind: 24242, tags: []))
    }
}
