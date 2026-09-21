import XCTest

/// `AvatarView` draws its circle at its own `size` (default 40). An external
/// `.frame(width:height:)` only declares a layout box — it does not resize the
/// content — so a call site that wraps the default-sized avatar in a frame
/// renders at 40pt inside a box of some other size: too small in a large box,
/// spilling over its neighbours in a small one.
///
/// This scans the app's own sources so the pattern cannot creep back in.
final class AvatarSizingTests: XCTestCase {

    /// Line numbers of `AvatarView(...)` call sites that pass no `size:` and are
    /// immediately followed by a square `.frame(width:height:)`.
    private func offendingLines(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        var offenders: [Int] = []

        for (index, line) in lines.enumerated() {
            guard line.contains("AvatarView("), !line.contains("struct AvatarView") else { continue }

            // Walk to the closing paren of the call, which may span lines.
            var depth = 0
            var end = index
            while end < lines.count {
                depth += lines[end].filter { $0 == "(" }.count
                depth -= lines[end].filter { $0 == ")" }.count
                if depth <= 0 { break }
                end += 1
            }
            let call = lines[index...min(end, lines.count - 1)].joined(separator: "\n")
            if call.contains("size:") { continue }

            // The modifier chain applied to that call.
            var cursor = end + 1
            while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                if lines[cursor].contains(".frame(width:") {
                    offenders.append(index + 1)
                    break
                }
                cursor += 1
            }
        }

        return offenders
    }

    /// The scanner has to be able to fail, or a clean result proves nothing.
    func testScannerFlagsAFramedDefaultAvatar() {
        let bad = """
        HStack {
            AvatarView(url: url, pubkey: hex)
                .frame(width: 64, height: 64)
        }
        """
        XCTAssertEqual(offendingLines(in: bad), [2])

        let multiline = """
        AvatarView(
            url: url,
            pubkey: hex
        )
        .frame(width: 64, height: 64)
        """
        XCTAssertEqual(offendingLines(in: multiline), [1])
    }

    func testScannerAcceptsAnExplicitSize() {
        let good = """
        AvatarView(url: url, pubkey: hex, size: 64)
            .overlay(Circle().stroke(Color.havenPurple, lineWidth: 1.5))
        """
        XCTAssertEqual(offendingLines(in: good), [])
    }

    func testNoAppCallSiteFramesADefaultSizedAvatar() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MediaLogicTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MediaLogicTests (package)
            .deletingLastPathComponent()   // HavenApp

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            return XCTFail("could not walk \(appRoot.path)")
        }

        var scanned = 0
        var findings: [String] = []
        for case let url as URL in walker {
            guard url.pathExtension == "swift" else { continue }
            // This file's own fixtures contain the pattern on purpose.
            guard !url.path.contains("MediaLogicTests") else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard source.contains("AvatarView(") else { continue }
            scanned += 1
            for line in offendingLines(in: source) {
                findings.append("\(url.lastPathComponent):\(line)")
            }
        }

        // If the walk found nothing to scan, the assertion below is vacuous.
        XCTAssertGreaterThan(scanned, 5, "expected to scan the app's avatar call sites")
        XCTAssertEqual(findings, [], "pass size: to AvatarView instead of wrapping it in .frame()")
    }
}
