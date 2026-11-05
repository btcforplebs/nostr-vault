import XCTest
@testable import MediaLogic

/// Mesh copy v2 (docs/MESH_COPY_V2_CONTRACT.md). Reads Tal's fixtures in
/// docs/fixtures/mesh-copy straight from the repo, so a contract change
/// reaches this test without a copy to keep in step. Android reads the same
/// files.
final class MeshCopyV2Tests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures/mesh-copy")

    static func fixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name + ".json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: COPY lines (§3.3)

    func testProgressLinesMatchFixture() throws {
        let cases = try XCTUnwrap(Self.fixture("progress-v2-lines")["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 5)
        for c in cases {
            let line = try XCTUnwrap(c["line"] as? String)
            let got = MeshCopyV2.parseLine(line)
            guard let expect = c["expect"] as? [String: Any] else {
                XCTAssertNil(got, line)
                continue
            }
            let p = try XCTUnwrap(got, line)
            let bytes = try XCTUnwrap(expect["bytes"] as? [NSNumber], line).map(\.int64Value)
            let items = try XCTUnwrap(expect["items"] as? [NSNumber], line).map(\.intValue)
            XCTAssertEqual(p.stage, expect["stage"] as? String, line)
            XCTAssertEqual(p.part, expect["part"] as? String, line)
            XCTAssertEqual([p.bytes.done, p.bytes.total], bytes, line)
            XCTAssertEqual([p.items.done, p.items.total], items, line)
            XCTAssertEqual(p.source, expect["source"] as? String, line)
            XCTAssertEqual(p.error, expect["error"] as? String ?? "", line)
        }
    }

    /// The free-space line carries bytes=<free>/<need>; the app words it from
    /// those numbers and never measures the disk itself.
    func testNeedsSpaceWordsTheEngineNumbers() throws {
        let p = try XCTUnwrap(MeshCopyV2.parseLine(
            "COPY stage=failed part=- bytes=1500000000/4200000000 items=0/0 source=mesh error=needs_space"))
        XCTAssertEqual(MeshCopyV2.message(for: p, name: "Mac mini"), "Needs 4.2 GB free, this device has 1.5 GB")
    }

    // MARK: Errors (§7)

    func testErrorTableMatchesFixture() throws {
        let rows = try XCTUnwrap(Self.fixture("errors-v2")["errors"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["code"] as? String }), Set(MeshCopyV2.errors.map(\.code)))
        for r in rows {
            let code = try XCTUnwrap(r["code"] as? String)
            let info = try XCTUnwrap(MeshCopyV2.error(code), code)
            XCTAssertEqual(info.action.rawValue, r["b"] as? String, code)
            XCTAssertEqual(info.line, r["line"] as? String, code)
        }
    }

    func testMessageFillsNameAndSkipsSilentErrors() throws {
        let hash = try XCTUnwrap(MeshCopyV2.parseLine(
            "COPY stage=failed part=notes bytes=0/9 items=0/3 source=mesh error=hash_mismatch"))
        XCTAssertEqual(MeshCopyV2.message(for: hash, name: " "),
                       "The copy from your other device arrived damaged; it starts over next time")
        let done = try XCTUnwrap(MeshCopyV2.parseLine("COPY stage=done part=- bytes=0/0 items=1/1 source=mesh"))
        XCTAssertNil(MeshCopyV2.message(for: done, name: "Mac"))
    }
}
