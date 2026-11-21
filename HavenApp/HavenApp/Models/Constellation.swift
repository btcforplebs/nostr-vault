import Foundation

/// A face for an account with no picture: a small constellation drawn from the
/// pubkey (Logen 2026-11-21). The spec is RESEARCH/NV_CONSTELLATION_AVATAR_SPEC.md
/// (v2); web-vault `src/components/constellation.js` (PR 2337) is the reference,
/// and `web-vault/test/fixtures/CONSTELLATION_VECTORS.json` is checked by
/// `ConstellationTests`. Change one, change all three and the vectors.
///
/// Everything comes from one number stream: FNV-1a over the 32 pubkey bytes
/// seeds mulberry32. Coordinates are in a 100x100 box, rounded to 2 decimals
/// before they are used again; colours are HSL turned into whole-number RGB.
struct Constellation: Equatable {
    struct Star: Equatable { var x: Double; var y: Double; var r: Double }
    struct Dot: Equatable { var x: Double; var y: Double; var r: Double }
    struct Cloud: Equatable { var x: Double; var y: Double; var radius: Double; var color: String; var alpha: Double }

    var hue: Int
    var stars: [Star]
    /// `[min, max]` star indexes, in the order added.
    var links: [[Int]]
    /// The bright star.
    var you: Int
    var dust: [Dot]
    var clouds: [Cloud]
    var skyInner: String
    var skyOuter: String
    var line: String
    var star: String
    var glow: String

    static func r2(_ x: Double) -> Double { (x * 100 + 0.5).rounded(.down) / 100 }

    /// FNV-1a, 32 bit.
    static func fnv1a(_ bytes: [UInt8]) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for b in bytes { h = (h ^ UInt32(b)) &* 0x01000193 }
        return h
    }

    /// mulberry32: each call is the next number in [0, 1).
    struct Mulberry32 {
        var s: UInt32
        mutating func next() -> Double {
            s = s &+ 0x6D2B79F5
            var t = s
            t = (t ^ (t >> 15)) &* (t | 1)
            t = t ^ (t &+ ((t ^ (t >> 7)) &* (t | 61)))
            return Double(t ^ (t >> 14)) / 4294967296
        }
    }

    /// HSL (h 0-359, s and l 0-100) -> "#rrggbb", each channel rounded half up (the CSS formula).
    static func hslHex(_ h: Int, _ s: Double, _ l: Double) -> String {
        let s = s / 100, l = l / 100
        let a = s * min(l, 1 - l)
        func f(_ n: Double) -> Double {
            let k = (n + Double(h) / 30).truncatingRemainder(dividingBy: 12)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return "#" + [f(0), f(8), f(4)].map { String(format: "%02x", Int((($0 * 255) + 0.5).rounded(.down))) }.joined()
    }

    /// The pubkey's 32 bytes, or nil if it is not 64 hex characters.
    static func bytes(ofHex hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count == 64 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(32)
        var i = 0
        while i < 64 {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }

    private static let minGap = 12.0, sky = 44.0, maxTries = 400, linkMax = 30.0, maxDegree = 4

    /// The drawing as numbers (the spec's steps 1-9), or nil for a key that is not 64 hex characters.
    init?(hex: String) {
        guard let bytes = Self.bytes(ofHex: hex.lowercased()) else { return nil }
        var rng = Mulberry32(s: Self.fnv1a(bytes))
        let r2 = Self.r2
        // 2. hue, 3. how many stars
        hue = Int((rng.next() * 360).rounded(.down))
        let n = 9 + Int((rng.next() * 5).rounded(.down))
        // 4. stars spread over the whole sky, never closer than minGap
        var stars: [Star] = []
        var tries = 0
        while tries < Self.maxTries && stars.count < n {
            tries += 1
            let a = rng.next() * 2 * Double.pi, r = Self.sky * rng.next().squareRoot()
            let p = Star(x: r2(50 + r * cos(a)), y: r2(50 + r * sin(a)), r: 0)
            if stars.allSatisfy({ ($0.x - p.x) * ($0.x - p.x) + ($0.y - p.y) * ($0.y - p.y) >= Self.minGap * Self.minGap }) {
                stars.append(p)
            }
        }
        // 5. sizes
        for i in stars.indices { stars[i].r = r2(2.2 + (rng.next() * 4).rounded(.down) * 0.4) }
        // 6. links: the shortest tree that reaches every star, then the shortest other links under linkMax
        func d2(_ i: Int, _ j: Int) -> Double {
            let dx = stars[i].x - stars[j].x, dy = stars[i].y - stars[j].y
            return r2(dx * dx + dy * dy)
        }
        var links: [[Int]] = []
        var degree = Array(repeating: 0, count: stars.count)
        var inTree = Array(repeating: false, count: stars.count)
        func add(_ i: Int, _ j: Int) { links.append([min(i, j), max(i, j)]); degree[i] += 1; degree[j] += 1 }
        if !stars.isEmpty { inTree[0] = true }
        var treeSize = stars.isEmpty ? 0 : 1
        while treeSize < stars.count {
            var best: (i: Int, j: Int, d: Double)?
            for i in stars.indices where inTree[i] {
                for j in stars.indices where !inTree[j] {
                    let d = d2(i, j)
                    if best == nil || d < best!.d { best = (i, j, d) } // a tie keeps the pair found first
                }
            }
            guard let b = best else { break }
            add(b.i, b.j); inTree[b.j] = true; treeSize += 1
        }
        let linked = Set(links.map { $0[0] * 64 + $0[1] })
        var others: [(i: Int, j: Int, d: Double)] = []
        for i in stars.indices { for j in stars.indices where j > i && !linked.contains(i * 64 + j) { others.append((i, j, d2(i, j))) } }
        others.sort { ($0.d, $0.i, $0.j) < ($1.d, $1.i, $1.j) }
        let limit = stars.count - 1 + stars.count / 2
        for o in others {
            if links.count >= limit { break }
            if o.d >= Self.linkMax * Self.linkMax || degree[o.i] >= Self.maxDegree || degree[o.j] >= Self.maxDegree { continue }
            add(o.i, o.j)
        }
        // 7. you: the star with the most links, then the one nearest the middle, then the lowest index
        func mid(_ i: Int) -> Double { (stars[i].x - 50) * (stars[i].x - 50) + (stars[i].y - 50) * (stars[i].y - 50) }
        var you = 0
        for i in stars.indices.dropFirst() where degree[i] > degree[you] || (degree[i] == degree[you] && mid(i) < mid(you)) { you = i }
        // 8. dust: 16 draws, kept only inside the circle
        var dust: [Dot] = []
        for _ in 0..<16 {
            let x = r2(6 + rng.next() * 88), y = r2(6 + rng.next() * 88), r = r2(0.5 + (rng.next() * 3).rounded(.down) * 0.25)
            if (x - 50) * (x - 50) + (y - 50) * (y - 50) <= 48 * 48 { dust.append(Dot(x: x, y: y, r: r)) }
        }
        // 9. two nebula clouds behind everything
        func cloud(_ radius: Double, _ h: Int, _ s: Double, _ l: Double, _ alpha: Double) -> Cloud {
            let a = rng.next() * 2 * Double.pi, d = 10 + rng.next() * 20
            return Cloud(x: r2(50 + d * cos(a)), y: r2(50 + d * sin(a)), radius: radius, color: Self.hslHex(h, s, l), alpha: alpha)
        }
        let c1 = cloud(42, (hue + 50) % 360, 75, 50, 0.5)
        let c2 = cloud(34, (hue + 320) % 360, 70, 45, 0.4)
        self.stars = stars
        self.links = links
        self.you = you
        self.dust = dust
        self.clouds = [c1, c2]
        skyInner = Self.hslHex(hue, 55, 24)
        skyOuter = Self.hslHex((hue + 30) % 360, 60, 8)
        line = Self.hslHex(hue, 85, 84)
        star = Self.hslHex(hue, 60, 96)
        glow = Self.hslHex(hue, 90, 85)
    }
}
