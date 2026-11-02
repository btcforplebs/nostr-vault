import XCTest
@testable import MediaLogic

/// List-wipe audit 2026-11-02: after a factory reset the next 10063/10006/10015
/// edit has to start from the network copy, not from what this device
/// remembered publishing before the reset.
final class ListPublishResetTests: XCTestCase {
    func testResetForgetsWhatThisDevicePublishedAndKeepsTheRest() throws {
        let suite = "ListPublishResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(ListMerge.basesFileName)
        ListMerge.Bases(file: file).put("10006:abc", ["wss://blocked.example"])
        XCTAssertNotNil(ListMerge.Bases(file: file).get("10006:abc"))

        defaults.set(["https://blossom.example"], forKey: "serverListManaged.abc")
        defaults.set(Data("{}".utf8), forKey: "interestList.abc")
        FreshAccountKeys.mark("abc", defaults: defaults)
        defaults.set("kept", forKey: "serverListStamps.v2")
        defaults.set("kept", forKey: "somethingElse")

        ListPublishReset.clear(defaults: defaults, basesFile: file)

        XCTAssertNil(ListMerge.Bases(file: file).get("10006:abc"), "the next 10006 edit must not drop relays as removed here")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(defaults.object(forKey: "serverListManaged.abc"), "the next 10063 edit must not drop servers as removed here")
        XCTAssertNil(defaults.object(forKey: "interestList.abc"))
        XCTAssertFalse(FreshAccountKeys.isFresh("abc", defaults: defaults), "a restored key is asked about on the network")
        XCTAssertEqual(defaults.string(forKey: "serverListStamps.v2"), "kept")
        XCTAssertEqual(defaults.string(forKey: "somethingElse"), "kept")
    }

    func testResetWithNothingStoredIsFine() throws {
        let suite = "ListPublishResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ListPublishReset.clear(defaults: defaults, basesFile: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
