import XCTest

/// A user's lists are never overwritten by accident (Logen 2026-10-31): kind 0, 3, 10000, 10002, 10006, 10015,
/// 10050 and 10063 are signed only from the places listed here. Any new place that signs one of them, or any new
/// signing call that takes its kind from a variable, fails this test until someone reviews it and adds it.
/// Paths from Tron's audit at 633d5552 (RESEARCH/NV_LIST_OVERWRITE_AUDIT_633D5552.md). Android twin:
/// UserListSignGuardTest.kt.
///
/// The last tests pin the fixes for the live paths the audit found (iPhone/Mac, 2026-10-31): nothing signs a list
/// on load, a Save edits the newest copy fetched right before it, and one relay saying "none" is not "you have none".
final class UserListSignGuardTests: XCTestCase {

    private static let listKinds: Set<String> = ["0", "3", "10000", "10002", "10006", "10015", "10050", "10063"]

    /// A sign call and its kind argument (not a declaration).
    private static let signCall = try! NSRegularExpression(
        pattern: #"(?<!func )\b(signEventAsync|signEvent|publishEntryList)\s*\(\s*(?:kind:\s*)?([A-Za-z0-9_.]+)"#)

    /// The app's own sources (not the tests), keyed by path under HavenApp/, whitespace collapsed.
    private static let sources: [String: String] = {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // HavenApp
        var out: [String: String] = [:]
        for dir in ["HavenApp", "HavenApp-iOS", "NostrVaultShare", "NostrVaultWidgets"] {
            let base = appRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rel = dir + url.path.dropFirst(base.path.count)
                out[rel] = collapse(text)
            }
        }
        return out
    }()

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func calls(in text: String) -> [String] {
        let ns = text as NSString
        return signCall.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 2)) }
    }

    /// (files that sign a list kind -> kinds, files that sign a kind they are handed -> argument).
    private func scan() -> ([String: Set<String>], [String: Set<String>]) {
        var lists: [String: Set<String>] = [:], generic: [String: Set<String>] = [:]
        for (path, text) in Self.sources {
            for arg in Self.calls(in: text) {
                if Self.listKinds.contains(arg) { lists[path, default: []].insert(arg) }
                else if Int(arg) == nil { generic[path, default: []].insert(arg) }
            }
        }
        return (lists, generic)
    }

    func testThePatternCatchesEveryWayAListIsSigned() {
        XCTAssertGreaterThan(Self.sources.count, 300, "the app's sources were found")
        let samples = [
            "guard let event = await NostrService.shared.signEventAsync(\n kind: 3, content: c, tags: t)",
            "await signEventAsync(kind: 10063, content: \"\", tags: tags)",
            "await publishEntryList(kind: 10006, name: \"relay\"",
        ]
        XCTAssertEqual(samples.flatMap { Self.calls(in: Self.collapse($0)) }, ["3", "10063", "10006"])
        XCTAssertEqual(Self.calls(in: "func signEventAsync(kind: Int, content: String"), [], "a declaration is not a call")
    }

    func testOnlyThesePlacesSignAUserList() {
        XCTAssertEqual(scan().0, [
            // Follow / unfollow taps, and (⛔ below) the self-heal on load, through publishContactList.
            "HavenApp/Services/Feed/FeedService+Follow.swift": ["3"],
            // Interests: the hashtag follow tap.
            "HavenApp/Services/InterestListService.swift": ["10015"],
            // 10000 Block, 10006 relay sets, 10063 media servers.
            "HavenApp/Services/Nostr/NostrService+ListPublishing.swift": ["10000", "10006", "10063"],
            // Save in Relays.
            "HavenApp/Services/Nostr/NostrService+RelayListSave.swift": ["10002", "10050"],
            // Save in Edit profile.
            "HavenApp/Views/Profile/ProfileEditView.swift": ["0"],
            // A new account finishing setup (no list exists yet).
            "HavenApp/Views/SetupWizard/SetupWizardView.swift": ["0", "10002"],
        ])
    }

    func testNoNewSignerTakesItsKindFromAVariable() {
        // Each of these signs a kind it is handed. A new one could sign a list; review it, then add it here.
        XCTAssertEqual(scan().1, [
            "HavenApp/Services/ModePostPublisher.swift": ["kind"],
            "HavenApp/Services/NIP17Service.swift": ["eventJSON"],
            "HavenApp/Services/Nostr/NostrService+ListPublishing.swift": ["kind"],
            "HavenApp/Services/Nostr/NostrService+Lookups.swift": ["VertexReputation.requestKind"],
            "HavenApp/Services/Nostr/NostrService+Signing.swift": ["_", "eventJSON", "kind"],
        ])
    }

    // MARK: - The audit's live paths (Tron 633d5552), fixed 2026-10-31.

    private func src(_ path: String) -> String { Self.sources[path] ?? "" }

    func testLoadingTheFollowListNeverReSignsIt() throws {
        XCTAssertFalse(src("HavenApp/Services/Feed/FeedService+ContactList.swift").contains("self.publishContactList()"))
    }

    func testAFollowTapReadsTheNewestKind3BeforeSigning() throws {
        let follow = src("HavenApp/Services/Feed/FeedService+Follow.swift")
        XCTAssertNotNil(follow.range(of: #"lookupNewestReplaceable\( ?kind: 3,"#, options: .regularExpression))
        XCTAssertTrue(follow.contains("ListMerge.contactEdit(base: base.tags, before: before, after: attempted)"),
                      "the tap's change goes onto the fetched list, every other tag kept")
    }

    func testOneRelaySayingNoneIsNotEnoughToPublishA10063Or10006() throws {
        let publishing = src("HavenApp/Services/Nostr/NostrService+ListPublishing.swift")
        XCTAssertFalse(publishing.contains("lookup.event == nil && lookup.answered == 0"))
        XCTAssertFalse(publishing.contains("} else { existing = serverLists[owner] ?? [] }"))
    }

    func testOneRelayAnsweringIsNotEnoughToPublishA10015() throws {
        XCTAssertFalse(src("HavenApp/Services/InterestListService.swift").contains("newest != nil || answered > 0"))
    }

    func testSaveInRelaysReadsTheNewestListAtSave() throws {
        let view = src("HavenApp/Views/RelayMatrixView.swift")
        let save = view.components(separatedBy: "private func save()").last?
            .components(separatedBy: "private func commit(").first ?? ""
        XCTAssertTrue(save.contains("await NostrService.shared.lookupOwnerRelayLists()"), "Save reads the lists again")
        XCTAssertTrue(save.contains("RelayDraft.saveCheck(opened: state.published, fresh: fresh, plan: plan)"))
    }
}
