import XCTest
@testable import MediaLogic

/// Audit #17: a picked backup zip is read where it is, with its scope held
/// until the reader finishes, and no restore call site copies it to temp.
final class ScopedImportFileTests: XCTestCase {
    private final class Calls: @unchecked Sendable { var log: [String] = [] }

    private func access(_ calls: Calls, scoped: Bool) -> ScopedImportFile.Access {
        .init(start: { _ in calls.log.append("start"); return scoped },
              stop: { _ in calls.log.append("stop") },
              download: { _ in calls.log.append("download") })
    }

    func testReadsInPlaceAndHoldsScopeUntilFinished() {
        let calls = Calls()
        let url = URL(fileURLWithPath: "/picked/backup.zip")
        var finish: (@Sendable () -> Void)?
        ScopedImportFile.read(url, access: access(calls, scoped: true)) { path, finished in
            XCTAssertEqual(path, url.path)
            finish = finished
        }
        XCTAssertEqual(calls.log, ["start", "download"], "scope must stay open after read returns")
        finish?()
        finish?()
        XCTAssertEqual(calls.log, ["start", "download", "stop"])
    }

    func testUnscopedFileIsReadAndNeverStopped() {
        let calls = Calls()
        ScopedImportFile.read(URL(fileURLWithPath: "/a.zip"), access: access(calls, scoped: false)) { _, finished in finished() }
        XCTAssertEqual(calls.log, ["start", "download"])
    }

    /// Every restore call site passes the path it was given, never a temp copy.
    func testNoRestoreCallSiteCopiesToTemp() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let calls = try NSRegularExpression(pattern: #"(runOwnBackupRestore|runBlossomImportStrippingExtensions)\(config:[^)]*inputPath: ([^)]+?)\)\s*\{"#)
        var sites: [String] = []
        for dir in ["HavenApp", "HavenApp-iOS"] {
            let e = FileManager.default.enumerator(at: app.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            while let f = e?.nextObject() as? URL {
                guard f.pathExtension == "swift", let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let ns = text as NSString
                for m in calls.matches(in: text, range: NSRange(location: 0, length: ns.length))
                where ns.substring(with: m.range(at: 2)) != "String" {  // the declarations
                    sites.append("\(f.lastPathComponent):\(ns.substring(with: m.range(at: 2)))")
                }
            }
        }
        // Positive control: the scan sees all four restore sites.
        XCTAssertGreaterThanOrEqual(sites.count, 4, "\(sites)")
        XCTAssertEqual(sites.filter { !$0.hasSuffix(":path") }, [], "a restore reads a copy, not the picked file")
    }
}
