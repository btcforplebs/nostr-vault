import XCTest

/// The relay's settings go to Go's own locked map (SetHavenEnvC,
/// haven-go/host_env.go), never through libc setenv(3). setenv reallocates
/// `environ` with no lock while network threads read it in getenv, the
/// use-after-free behind the cold-launch getenv SIGSEGV (#1908). The app
/// can't be built here, so this reads its source, like the Go guard
/// TestNoDirectProcessEnvInRelay does for haven-go.
final class HostEnvWiringTests: XCTestCase {
    private var havenApp: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: havenApp.appendingPathComponent(path), encoding: .utf8)
    }

    /// Code only: comment lines may name setenv(3) to explain why it is out.
    private func codeLines(_ src: String) -> [Substring] {
        src.split(separator: "\n", omittingEmptySubsequences: false).filter {
            let t = $0.drop(while: { $0 == " " || $0 == "\t" })
            return !t.hasPrefix("//") && !t.hasPrefix("*") && !t.hasPrefix("/*")
        }
    }

    func testNoAppSourceWritesTheProcessEnvironment() throws {
        let writes = try NSRegularExpression(pattern: #"\b(setenv|unsetenv|putenv)\s*\("#)
        let kinds: Set<String> = ["swift", "m", "mm", "c", "h"]
        let files = FileManager.default.enumerator(at: havenApp, includingPropertiesForKeys: nil)!
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in files where kinds.contains(url.pathExtension) {
            // MediaLogicTests/Sources are symlinks into the app (scanned
            // there); this file itself names the pattern.
            if url.path.contains("/MediaLogicTests/") { continue }
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for line in codeLines(src) {
                let s = String(line)
                if writes.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    hits.append("\(url.lastPathComponent): \(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 500, "scanned too few files; the guard would pass vacuously")
        XCTAssertEqual(hits, [], "process-environment writes; hand settings to Go with RelayProcessManager.handToGo")
    }

    /// Every relay start, import and backup hands its settings through the
    /// one seam, and only the seam calls SetHavenEnvC.
    func testSettingsReachGoThroughHandToGo() throws {
        let seamFile = try source("HavenApp/Services/Relay/RelayProcessManager+Backup.swift")
        let start = try XCTUnwrap(seamFile.range(of: "nonisolated static func handToGo(_ env: [String: String]) {"))
        let rest = seamFile[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n")).lowerBound
        let body = rest[..<end]
        XCTAssertTrue(body.contains("SetHavenEnvC("))

        let callers = [
            "HavenApp/Services/Relay/RelayProcessManager+Start.swift": 2, // settings + first-run flag
            "HavenApp/Services/Relay/RelayProcessManager+Import.swift": 1,
            "HavenApp/Services/Relay/RelayProcessManager+Backup.swift": 1,
        ]
        for (path, uses) in callers {
            let src = try source(path)
            XCTAssertEqual(src.components(separatedBy: "Self.handToGo(").count - 1, uses, path)
            let direct = codeLines(src).filter { $0.contains("SetHavenEnvC(") }.count
            XCTAssertEqual(direct, path.hasSuffix("+Backup.swift") ? 1 : 0, "\(path) calls SetHavenEnvC outside handToGo")
        }
    }
}
