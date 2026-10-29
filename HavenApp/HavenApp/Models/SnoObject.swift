import Foundation

/// A Simple Nostr Object: a small 3D object carried whole in a `kind 33331`
/// event's content (DECK-0003, github.com/arkin0x/cyberspace decks/DECK-0003-sno.md).
///
/// The reader follows sno-core's `fromPayload`, the format author's own
/// TypeScript reader, rule for rule. Every §1.9 check runs before anything is
/// drawn, and a payload that fails one is refused whole with the reason: a face
/// index past the end of the vertex list is not something to draw around.
struct SnoObject: Equatable {
    static let kind = 33331

    enum Mode: String { case solid, points, lines }

    /// One sRGB colour, eight bits a channel.
    struct RGB: Equatable {
        var r: UInt8, g: UInt8, b: UInt8
    }

    /// One placement of another object (§1.10). We draw a placeholder where
    /// it stands rather than fetching it.
    struct Part: Equatable {
        /// The placed object's origin, in parent model units.
        var at: SIMD3<Double>
    }

    let name: String
    let mode: Mode
    /// Positions in model units, in the §2 frame: X right, Y up, +Z toward the viewer.
    let positions: [SIMD3<Double>]
    /// One per vertex.
    let colors: [RGB]
    let faces: [SIMD3<Int>]
    /// One per face when the payload carries `facecolors`, else nil.
    let faceColors: [RGB]?
    /// 0.1 to 1. §1.11's floor means nothing is drawn wholly invisible.
    let opacity: Double
    let parts: [Part]

    // MARK: - Reading

    enum Rejection: Error, Equatable {
        case notJSON
        case version
        case name
        case missing(String)
        case mode
        case unit
        case lengthMismatch
        case vertex(Int)
        case ticks
        case palette
        case color(Int)
        case face(Int)
        case faceColors
        case up
        case spin
        case refs
        case parts
        case nullField(String)

        /// Why, in words, for the line drawn in place of the object (§3.1:
        /// say why rather than failing silently).
        var reason: String {
            switch self {
            case .notJSON: return "its content is not an object"
            case .version: return "it is a format version this app does not read"
            case .name: return "it has no name"
            case .missing(let field): return "it has no \(field)"
            case .mode: return "its drawing mode is unknown"
            case .unit: return "its scale is out of range"
            case .lengthMismatch: return "its vertices and colors do not match up"
            case .vertex(let i): return "vertex \(i) is not three whole numbers"
            case .ticks: return "its fine positions do not match its vertices"
            case .palette: return "its palette is not one this app can read"
            case .color(let i): return "the color of vertex \(i) is not in its palette"
            case .face(let i): return "face \(i) points at a vertex that is not there"
            case .faceColors: return "its face colors do not match its faces"
            case .up: return "its up setting is not true or false"
            case .spin: return "its bearing is out of range"
            case .refs: return "it places an object it does not name properly"
            case .parts: return "a placement in it is out of range"
            case .nullField(let field): return "its \(field) is empty"
            }
        }
    }

    /// The object in an event's content, or the reason it cannot be drawn.
    static func read(_ content: String) -> Result<SnoObject, Rejection> {
        guard let data = content.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let p = raw as? [String: Any] else { return .failure(.notJSON) }
        do { return .success(try read(p)) } catch let r as Rejection { return .failure(r) } catch { return .failure(.notJSON) }
    }

    /// `true` for a JSON integer: not a boolean, not a string, no fraction.
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !isBool(n), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    static let ticksPerUnit = 120
    static let partReach = 64 * ticksPerUnit
    static let maxUnit = 84

    private static func read(_ p: [String: Any]) throws -> SnoObject {
        // §1.1a: a `type` field is ignored wherever it appears.
        let v = integer(p["v"])
        guard v == 1 || v == 2 else { throw Rejection.version }
        guard let rawName = p["name"] as? String,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Rejection.name }
        // §1.1: an optional field written as null is refused, not read as absent.
        // `extent` and `opacity` are repaired instead, so they are not here.
        for field in ["ticks", "palette", "facecolors", "up", "spin", "refs", "parts"] where p[field] is NSNull {
            throw Rejection.nullField(field)
        }
        guard let vertices = p["vertices"] as? [Any] else { throw Rejection.missing("vertices") }
        guard let colors = p["colors"] as? [Any] else { throw Rejection.missing("colors") }
        guard let faces = p["faces"] as? [Any] else { throw Rejection.missing("faces") }
        guard vertices.count == colors.count else { throw Rejection.lengthMismatch }
        guard let modeWord = p["mode"] as? String, let mode = Mode(rawValue: modeWord) else { throw Rejection.mode }
        guard let unit = integer(p["unit"]), (0...maxUnit).contains(unit) else { throw Rejection.unit }
        guard let rest = unpackTicks(p["ticks"], count: vertices.count) else { throw Rejection.ticks }
        if let up = p["up"] {
            guard let flag = up as? NSNumber, isBool(flag) else { throw Rejection.up }
        }
        if p["spin"] != nil {
            guard let spin = integer(p["spin"]), (0...359).contains(spin) else { throw Rejection.spin }
        }
        guard let palette = resolvePalette(p["palette"]) else { throw Rejection.palette }

        // Version 1's Z points away from the viewer; negating it on read shows
        // the object as its author built it (§2).
        let zSign: Double = v == 1 ? -1 : 1
        var positions: [SIMD3<Double>] = []
        var vertexColors: [RGB] = []
        positions.reserveCapacity(vertices.count)
        vertexColors.reserveCapacity(vertices.count)
        for i in 0..<vertices.count {
            guard let triple = vertices[i] as? [Any], triple.count == 3 else { throw Rejection.vertex(i) }
            let whole = triple.compactMap { integer($0) }
            guard whole.count == 3 else { throw Rejection.vertex(i) }
            let r = rest[i]
            let t = ticksPerUnit
            positions.append(SIMD3(Double(whole[0] * t + r.x) / Double(t),
                                   Double(whole[1] * t + r.y) / Double(t),
                                   zSign * Double(whole[2] * t + r.z) / Double(t)))
            if let literal = colors[i] as? [Any] {
                // A literal [r, g, b] in 0...1 is version 1's form. sno-core also
                // takes it in a version 2 payload: objects written between the
                // frame change and the palette change carry it (§5).
                let channels = literal.compactMap { number($0) }
                guard literal.count == 3, channels.count == 3 else { throw Rejection.color(i) }
                vertexColors.append(RGB(r: unitByte(channels[0]), g: unitByte(channels[1]), b: unitByte(channels[2])))
            } else {
                guard v == 2, let index = integer(colors[i]), index >= 0, index < palette.count else {
                    throw Rejection.color(i)
                }
                vertexColors.append(palette[index])
            }
        }

        var faceList: [SIMD3<Int>] = []
        faceList.reserveCapacity(faces.count)
        for (i, f) in faces.enumerated() {
            guard let corners = f as? [Any], corners.count == 3 else { throw Rejection.face(i) }
            let idx = corners.compactMap { integer($0) }
            guard idx.count == 3, idx.allSatisfy({ $0 >= 0 && $0 < positions.count }),
                  Set(idx).count == 3 else { throw Rejection.face(i) }
            faceList.append(SIMD3(idx[0], idx[1], idx[2]))
        }

        var faceColors: [RGB]?
        if let packed = p["facecolors"] {
            guard let indices = unpackFaceColors(packed, count: faceList.count, paletteSize: palette.count) else {
                throw Rejection.faceColors
            }
            faceColors = indices.map { palette[$0] }
        }

        // §1.9 rules 11 and 12. A placement naming a ref that is not there is a
        // rejection, which the range check gives when `refs` is absent.
        var refCount = 0
        if let refs = p["refs"] {
            guard let list = refs as? [Any], list.allSatisfy(validRef) else { throw Rejection.refs }
            refCount = list.count
        }
        var parts: [Part] = []
        if let rawParts = p["parts"] {
            guard let list = rawParts as? [Any] else { throw Rejection.parts }
            for entry in list {
                guard let e = entry as? [Any], e.count == 8 else { throw Rejection.parts }
                let n = e.compactMap { integer($0) }
                guard n.count == 8, n[0] >= 0, n[0] < refCount,
                      n[1...3].allSatisfy({ abs($0) <= partReach }),
                      n[4...6].allSatisfy({ (0...359).contains($0) }),
                      (0...maxUnit).contains(unit + n[7]) else { throw Rejection.parts }
                let t = Double(ticksPerUnit)
                parts.append(Part(at: SIMD3(Double(n[1]) / t, Double(n[2]) / t, zSign * Double(n[3]) / t)))
            }
        }

        // §1.11: repaired, never refused. 1...9 is drawn at 10.
        var opacity = 1.0
        if let o = integer(p["opacity"]), (1...99).contains(o) { opacity = Double(max(o, 10)) / 100 }

        return SnoObject(name: String(rawName.prefix(64)), mode: mode, positions: positions,
                         colors: vertexColors, faces: faceList, faceColors: faceColors,
                         opacity: opacity, parts: parts)
    }

    private static func unitByte(_ x: Double) -> UInt8 {
        UInt8((min(max(x, 0), 1) * 255).rounded())
    }

    /// The `ticks` column, one remainder per vertex, or nil when it does not
    /// fit (§1.2): a triple is one vertex, `-N` is N whole-unit vertices.
    static func unpackTicks(_ packed: Any?, count: Int) -> [SIMD3<Int>]? {
        guard let packed else { return Array(repeating: .zero, count: count) }
        guard let list = packed as? [Any] else { return nil }
        var out: [SIMD3<Int>] = []
        for e in list {
            if let run = integer(e) {
                guard run < 0, out.count - run <= count else { return nil }
                out.append(contentsOf: repeatElement(.zero, count: -run))
            } else if let triple = e as? [Any], triple.count == 3 {
                let n = triple.compactMap { integer($0) }
                guard n.count == 3, n.allSatisfy({ (0..<ticksPerUnit).contains($0) }) else { return nil }
                out.append(SIMD3(n[0], n[1], n[2]))
            } else {
                return nil
            }
            if out.count > count { return nil }
        }
        return out.count == count ? out : nil
    }

    /// `facecolors` expanded to one palette index per face, or nil (§1.4a).
    static func unpackFaceColors(_ packed: Any, count: Int, paletteSize: Int) -> [Int]? {
        guard let list = packed as? [Any] else { return nil }
        var out: [Int] = []
        for e in list {
            guard let n = integer(e) else { return nil }
            if n < 0 {
                // A run repeats the index before it, so it cannot come first.
                guard let previous = out.last, out.count - n <= count else { return nil }
                out.append(contentsOf: repeatElement(previous, count: -n))
            } else {
                guard n < paletteSize else { return nil }
                out.append(n)
            }
            if out.count > count { return nil }
        }
        return out.count == count ? out : nil
    }

    private static func validRef(_ entry: Any) -> Bool {
        guard let r = entry as? [Any], (2...3).contains(r.count),
              let kind = r[0] as? String, let target = r[1] as? String else { return false }
        if r.count == 3, !(r[2] is String) { return false }
        switch kind {
        case "e": return target.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        case "a": return target.range(of: #"^33331:[0-9a-f]{64}:"#, options: .regularExpression) != nil
        default: return false
        }
    }

    /// The colours a payload's indices name (§1.3a). A palette published as
    /// its own event is not fetched; the built-in stands in for it, as §1.3b
    /// says a reader does until the reference resolves.
    static func resolvePalette(_ field: Any?) -> [RGB]? {
        guard let field else { return builtInPalette }
        if let name = field as? String {
            if name == "cyberspace-neon-256" { return builtInPalette }
            if name.range(of: #"^(nevent1|naddr1)[023456789acdefghjklmnpqrstuvwxyz]{20,}$"#,
                          options: .regularExpression) != nil { return builtInPalette }
            return nil
        }
        guard let list = field as? [Any], (2...256).contains(list.count) else { return nil }
        var out: [RGB] = []
        for e in list {
            guard let c = e as? [Any], c.count == 3 else { return nil }
            let n = c.compactMap { integer($0) }
            guard n.count == 3, n.allSatisfy({ (0...255).contains($0) }) else { return nil }
            out.append(RGB(r: UInt8(n[0]), g: UInt8(n[1]), b: UInt8(n[2])))
        }
        return out
    }

    /// `cyberspace-neon-256`, DECK-0003 Appendix C: 24 hues of 8 steps, 32
    /// steels, 32 signatures.
    static let builtInPalette: [RGB] = builtInHex.map {
        RGB(r: UInt8($0 >> 16 & 0xFF), g: UInt8($0 >> 8 & 0xFF), b: UInt8($0 & 0xFF))
    }

    private static let builtInHex: [UInt32] = [
        0x003632, 0x004D49, 0x006562, 0x007E7D, 0x009799, 0x00B2B8, 0x00CDD7, 0x00E8F9,
        0x003538, 0x004C51, 0x00636D, 0x007C8A, 0x0095A9, 0x00AFCA, 0x00C9ED, 0x6FDFFF,
        0x00343F, 0x004A5A, 0x006178, 0x007998, 0x0092BA, 0x00ABDF, 0x34C4FF, 0x93D8FF,
        0x003346, 0x004865, 0x005E86, 0x0075AB, 0x008DD2, 0x00A4FD, 0x6EBCFF, 0xA7D3FF,
        0x003052, 0x004476, 0x00589E, 0x006CCC, 0x017FFF, 0x5A9BFF, 0x8BB5FF, 0xB5CEFF,
        0x00266D, 0x002CAC, 0x1902FF, 0x374FFF, 0x5A73FF, 0x7E92FF, 0xA1AEFF, 0xC3C9FF,
        0x220088, 0x3700B7, 0x5000E7, 0x6837FF, 0x8064FF, 0x9B86FF, 0xB6A5FF, 0xD0C4FF,
        0x350079, 0x4F00A3, 0x6B00CD, 0x8B00F8, 0xA24BFF, 0xB875FF, 0xCD9AFF, 0xE1BCFF,
        0x420069, 0x5F008D, 0x7F00B1, 0xA200D5, 0xC600F8, 0xDD53FF, 0xED84FF, 0xF9AFFF,
        0x4B0058, 0x6B0076, 0x8E0094, 0xB200B1, 0xD900CD, 0xFF1AE7, 0xFF7DE2, 0xFFB1E6,
        0x520046, 0x74005F, 0x980077, 0xBE008E, 0xE600A4, 0xFF45B4, 0xFF87C0, 0xFFB5D2,
        0x570035, 0x7A0048, 0x9F005A, 0xC6006B, 0xEE007B, 0xFF538D, 0xFF8CA6, 0xFFB7C2,
        0x5A0024, 0x7E0031, 0xA3003D, 0xCB0047, 0xF4004E, 0xFF5B6A, 0xFF908E, 0xFFB9B4,
        0x5C0010, 0x800014, 0xA60013, 0xCE0006, 0xF22400, 0xFF613E, 0xFF9375, 0xFFBBA5,
        0x561200, 0x752200, 0x943300, 0xB44600, 0xD45A00, 0xF47000, 0xFF9652, 0xFFBD93,
        0x4B1F00, 0x683100, 0x854300, 0xA25700, 0xC06D00, 0xDE8300, 0xFC9B00, 0xFFC077,
        0x442600, 0x5E3800, 0x794C00, 0x946100, 0xB07800, 0xCC8F00, 0xE7A800, 0xFFC333,
        0x3E2A00, 0x563D00, 0x6E5300, 0x876900, 0xA08100, 0xB99900, 0xD2B300, 0xEBCE00,
        0x372D00, 0x4D4200, 0x635800, 0x797000, 0x8F8800, 0xA5A300, 0xB9BE00, 0xCDDA00,
        0x2F3000, 0x424600, 0x555E00, 0x677700, 0x779100, 0x87AD00, 0x94CA00, 0x9FE800,
        0x243400, 0x314B00, 0x3D6400, 0x457F00, 0x499B00, 0x45B900, 0x2CD900, 0x00F837,
        0x073900, 0x005108, 0x006A1F, 0x008436, 0x009F4E, 0x00BA67, 0x00D682, 0x00F39E,
        0x00381E, 0x005030, 0x006844, 0x00825B, 0x009C73, 0x00B78D, 0x00D3A9, 0x00EFC6,
        0x00372A, 0x004E3F, 0x006656, 0x00806E, 0x009A89, 0x00B4A5, 0x00D0C2, 0x00ECE1,
        0x010101, 0x020203, 0x050606, 0x090B0C, 0x0F1213, 0x15191A, 0x1B2021, 0x222728,
        0x282E30, 0x2F3638, 0x373E40, 0x3E4648, 0x454E50, 0x4D5658, 0x555E60, 0x5D6769,
        0x666F71, 0x6E787A, 0x778083, 0x80898C, 0x899294, 0x939B9D, 0x9CA4A6, 0xA6ADAF,
        0xB0B6B8, 0xBABFC1, 0xC4C9CA, 0xCED2D3, 0xD8DCDC, 0xE3E5E6, 0xEEEFEF, 0xF8F8F8,
        0x000000, 0xFFFFFF, 0x00E5FF, 0xFF3B6B, 0xF7931A, 0x52E39F, 0xC8F5FF, 0x6F8EA0,
        0x1D3547, 0x05070D, 0xFF00FF, 0x00FF00, 0x00FFFF, 0xFFFF00, 0xFF0000, 0x0000FF,
        0x39FF14, 0xFF6EC7, 0x7DF9FF, 0xB026FF, 0xFFFB00, 0xFF3300, 0x00FF9F, 0xFF007F,
        0x4D4DFF, 0xFFD300, 0x0A0F1A, 0x12182A, 0x1A0F24, 0x0F1F1C, 0x241016, 0x1C1C0F,
    ]
}
