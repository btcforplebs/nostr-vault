import XCTest
@testable import MediaLogic

final class TrustMapHazeTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    /// Keys spread like real ones, so the haze sample is a fair cut.
    private func key(_ n: Int) -> String {
        var x = UInt64(n) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        return (0..<4).map { _ -> String in
            x ^= x >> 33; x &*= 0xFF51_AFD7_ED55_8CCD; x ^= x >> 33
            return String(format: "%016llx", x)
        }.joined()
    }

    /// A web much bigger than the haze sample, like Logen's (16,181 people,
    /// 2,500 in the sample): 300 vouched-for (Close), the rest further out.
    private func layout() -> (TrustMap.HazeLayout, vouches: [String: Int], follows: Set<String>) {
        let follows = Set((1...50).map(key))
        let past = (51...12_000).map(key)
        var vouches: [String: Int] = [:]
        for (i, k) in past.enumerated() { vouches[k] = i < 300 ? 40 - i / 10 : 1 + i % 5 }
        let graph = follows.union(past)
        let layout = TrustMap.hazeLayout(graph: graph, inner: follows.union([me]), vouches: vouches, me: me,
                                         follows: follows, wot: true, faceScale: 1.8)
        return (layout, vouches, follows)
    }

    func testFacesOutsideTheHazeSampleStillSitOnTheCloseShell() {
        let (layout, vouches, _) = layout()
        XCTAssertEqual(layout.shell.count, TrustMap.hazeCap)
        // Most of the Close faces aren't in the sample at all.
        let faces = layout.layerFaces[.everyone]!
        let closeFaces = faces.filter { (vouches[$0] ?? 0) >= TrustMap.closeVouches }
        XCTAssertGreaterThan(closeFaces.filter { !layout.shell.contains($0) }.count, closeFaces.count / 2)
        // Every one of them is Close, sample or not; no further-out face is.
        XCTAssertTrue(closeFaces.allSatisfy(layout.close.contains))
        XCTAssertTrue(faces.filter { (vouches[$0] ?? 0) < TrustMap.closeVouches }.allSatisfy { !layout.close.contains($0) })
    }

    func testEveryoneFillsBothOuterRings() {
        let (layout, vouches, _) = layout()
        let shown = Int((Double(TrustMap.faceCount(for: .everyone)) * 1.8).rounded())
        let first = layout.layerFaces[.everyone]!.prefix(shown)
        let close = first.filter { (vouches[$0] ?? 0) >= TrustMap.closeVouches }.count
        // About half each, and well past the one or two Logen saw.
        XCTAssertEqual(Double(close), Double(shown) / 2, accuracy: 1)
        XCTAssertGreaterThanOrEqual(close, 30)
        XCTAssertGreaterThanOrEqual(first.count - close, 30)
    }
}
