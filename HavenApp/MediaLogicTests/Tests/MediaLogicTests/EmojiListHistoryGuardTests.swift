import XCTest

/// Every emoji list (10030) and emoji set (30030) the iPhone/Mac app signs keeps the old version in the vault first,
/// is stored in the vault before relays, and stops when the vault didn't keep the old copy: it goes through
/// ListVersionSave (NostrService.saveListVersion), never publishMergedList, which sends to relays without the vault
/// (RESEARCH/NV_EMOJI_LIST_HISTORY_AUDIT.md, Logen 2026-11-14). Android twin: EmojiListSave.kt.
final class EmojiListHistoryGuardTests: XCTestCase {

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()   // HavenApp

    private static func source(_ path: String) -> String {
        let text = (try? String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Every app source file that calls publishMergedList with an emoji kind.
    private static func emojiMergedListCalls() -> [String] {
        var out: [String] = []
        for dir in ["HavenApp", "HavenApp-iOS", "NostrVaultShare", "NostrVaultWidgets"] {
            let base = appRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = source(dir + url.path.dropFirst(base.path.count))
                if text.range(of: #"publishMergedList\( ?kind: ?(10030|30030)\b"#, options: .regularExpression) != nil {
                    out.append(dir + url.path.dropFirst(base.path.count))
                }
            }
        }
        return out.sorted()
    }

    func testThePatternFindsAnEmojiMergedListCall() {
        XCTAssertFalse(Self.source("HavenApp/Services/EmojiVaultStore.swift").isEmpty, "the app's sources were found")
        let sample = "await nostr.publishMergedList(kind: 30030, author: me".replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        XCTAssertNotNil(sample.range(of: #"publishMergedList\( ?kind: ?(10030|30030)\b"#, options: .regularExpression))
    }

    func testNoEmojiListOrSetSkipsTheVault() {
        XCTAssertEqual(Self.emojiMergedListCalls(), [])
    }

    func testTheEmojiPageAndGenmojiSaveThroughTheSafeSave() {
        XCTAssertTrue(Self.source("HavenApp/Services/EmojiVaultStore.swift").contains("saveListVersion(kind: 10030"))
        XCTAssertTrue(Self.source("HavenApp/Services/GenmojiSaver.swift").contains("saveListVersion(kind: 30030"))
    }
}
