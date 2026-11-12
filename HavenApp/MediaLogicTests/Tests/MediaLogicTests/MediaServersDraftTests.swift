import XCTest
@testable import MediaLogic

/// Settings › Media Servers gets a Save button (Logen via Tod, 2026-11-08):
/// adding or removing a typed server, a suggestion or a mesh vault only
/// changes the list on screen, and Save publishes the kind 10063 once.
final class MediaServersDraftTests: XCTestCase {
    private let a = "https://a.example.com"
    private let b = "https://b.example.com"
    private let vault = "fipsmesh://npub1vault/"
    private let other = "fipsmesh://npub1other/"

    func testOpensWithNoChanges() {
        let draft = MediaServersDraft(mirrors: [a])
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.changeCount, 0)
        XCTAssertEqual(draft.mirrors, [a])
    }

    func testTypedAddIsNormalizedAndUnsaved() {
        var draft = MediaServersDraft(mirrors: [a])
        XCTAssertTrue(draft.addMirror("  b.example.com// "))
        XCTAssertEqual(draft.mirrors, [a, b])
        XCTAssertEqual(draft.savedMirrors, [a])
        XCTAssertEqual(draft.changeCount, 1)
        XCTAssertFalse(draft.addMirror(b), "already on the list")
        XCTAssertFalse(draft.addMirror("   "), "empty entry")
    }

    func testHttpIsKept() {
        XCTAssertEqual(MediaServersDraft.normalized("http://box.local/"), "http://box.local")
    }

    func testRemoveThenAddBackIsNoChange() {
        var draft = MediaServersDraft(mirrors: [a, b])
        draft.removeMirror(a)
        XCTAssertEqual(draft.changeCount, 1)
        draft.addMirror(a)
        XCTAssertEqual(draft.changeCount, 0, "same servers as saved")
    }

    func testMeshAddAndRemoveAreUnsaved() {
        var draft = MediaServersDraft(mirrors: [a])
        draft.setMesh(vault, listed: true, published: false)
        draft.setMesh(other, listed: false, published: true)
        XCTAssertEqual(draft.changeCount, 2)
        XCTAssertTrue(draft.shownListed(vault, published: false))
        XCTAssertFalse(draft.shownListed(other, published: true))
        XCTAssertEqual(draft.savePlan.meshAdd, [vault])
        XCTAssertEqual(draft.savePlan.meshRemove, [other])
    }

    func testMeshUndoBeforeSaveLeavesNothingToPublish() {
        var draft = MediaServersDraft(mirrors: [a])
        draft.setMesh(vault, listed: true, published: false)
        draft.setMesh(vault, listed: false, published: false)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.savePlan.meshAdd, [])
        XCTAssertEqual(draft.savePlan.meshRemove, [])
    }

    /// One Save carries the typed servers and every mesh change together.
    func testSavePlanCarriesEverything() {
        var draft = MediaServersDraft(mirrors: [a])
        draft.addMirror(b)
        draft.removeMirror(a)
        draft.setMesh(vault, listed: true, published: false)
        let plan = draft.savePlan
        XCTAssertEqual(plan, .init(mirrors: [b], mirrorsChanged: true, meshAdd: [vault], meshRemove: []))
    }

    func testMeshOnlySaveDoesNotRewriteTypedServers() {
        var draft = MediaServersDraft(mirrors: [a])
        draft.setMesh(vault, listed: true, published: false)
        XCTAssertFalse(draft.savePlan.mirrorsChanged)
    }

    /// After Save there is nothing unsaved; the mesh row keeps showing the
    /// saved choice until the published list shows it.
    func testDidSaveClearsChangesAndAwaitsPublish() {
        var draft = MediaServersDraft(mirrors: [a])
        draft.addMirror(b)
        draft.setMesh(vault, listed: true, published: false)
        draft.didSave()
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.savedMirrors, [a, b])
        XCTAssertTrue(draft.shownListed(vault, published: false))
        draft.publishedListChanged()
        XCTAssertFalse(draft.shownListed(vault, published: false))
        XCTAssertTrue(draft.shownListed(vault, published: true))
    }

    func testDiscardRestoresSaved() {
        var draft = MediaServersDraft(mirrors: [a])
        draft.addMirror(b)
        draft.setMesh(vault, listed: true, published: false)
        draft.discard()
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.mirrors, [a])
        XCTAssertFalse(draft.shownListed(vault, published: false))
    }

    func testOutsideChangeFollowedOnlyWithoutEdits() {
        var clean = MediaServersDraft(mirrors: [a])
        clean.savedMirrorsChanged([a, b])
        XCTAssertEqual(clean.mirrors, [a, b])
        XCTAssertFalse(clean.hasChanges)

        var edited = MediaServersDraft(mirrors: [a])
        edited.removeMirror(a)
        edited.savedMirrorsChanged([a, b])
        XCTAssertEqual(edited.mirrors, [], "unsaved edits are kept")
    }

    // MARK: - Wiring (the views pull in the whole app; read their source)

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(of function: String, in src: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: function), "\(function) missing")
        let rest = src[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n")).lowerBound
        return String(rest[..<end])
    }

    private func count(_ needle: String, in src: String) -> Int {
        src.components(separatedBy: needle).count - 1
    }

    /// The page publishes the 10063 in one place, Save, and only through the draft.
    func testOnlySavePublishes() throws {
        let src = try source("HavenApp/Views/Settings/BlossomSettingsView.swift")
        XCTAssertEqual(count("publishServerList(", in: src), 1)
        let save = try body(of: "private func save() {", in: src)
        XCTAssertTrue(save.contains("NostrService.shared.publishServerList(meshAdd: plan.meshAdd, meshRemove: plan.meshRemove)"))
        XCTAssertEqual(count("blossomMirrors = ", in: src), 1, "typed servers are stored only by Save")
        XCTAssertFalse(src.contains("blossomMirrors.append("))
        XCTAssertFalse(src.contains("blossomMirrors.removeAll("))
        XCTAssertTrue(save.contains("configService.config.blossomMirrors = plan.mirrors"))
        XCTAssertTrue(save.contains("configService.save()"))
        let add = try body(of: "private func addMirror(_ typed: String) {", in: src)
        XCTAssertFalse(add.contains("configService"), "Add only changes the draft")
    }

    /// Your Vaults on the Mesh never publishes by itself.
    func testMeshSectionDoesNotPublish() throws {
        let src = try source("HavenApp/Views/Settings/MeshMediaServersSection.swift")
        XCTAssertFalse(src.contains("publishServerList"))
        XCTAssertTrue(src.contains("@Binding var draft: MediaServersDraft"))
        XCTAssertTrue(src.contains("draft.setMesh("))
    }

    /// Leaving with unsaved changes asks: Back on a stack, Done on a sheet,
    /// a sidebar row on Mac and iPad.
    func testLeavingAsks() throws {
        let page = try source("HavenApp/Views/Settings/BlossomSettingsView.swift")
        XCTAssertTrue(page.contains(".navigationBarBackButtonHidden(pushed && draft.hasChanges)"))
        XCTAssertTrue(page.contains(".interactiveDismissDisabled(draft.hasChanges)"))
        XCTAssertTrue(page.contains("Button(\"Save\")"))
        XCTAssertTrue(page.contains("Button(\"Discard\", role: .destructive)"))
        let settings = try source("HavenApp/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("if selectedTab == .blossom { MediaServersLeaveGuard.shared.requestLeave(go) }"))
        XCTAssertEqual(count("selectedTab = ", in: settings), 2, "every sidebar switch goes through select(_:)")
        for host in ["HavenApp/Views/Compose/UploadServersLink.swift", "HavenApp/Views/MediaGallery/MediaGalleryView.swift"] {
            let src = try source(host)
            XCTAssertTrue(src.contains("BlossomSettingsView(pushed: false)"), host)
            XCTAssertTrue(src.contains("MediaServersLeaveGuard.shared.requestLeave {"), host)
        }
    }
}
