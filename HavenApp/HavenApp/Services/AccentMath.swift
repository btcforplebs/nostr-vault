import Foundation

/// Colour maths, a port of web-vault/src/net/accent.js (pure Foundation, so
/// MediaLogicTests can test it). RGB is 0...255.
enum AccentMath {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// The ready-made row (web-vault/src/net/accent.js ACCENT_PRESETS). Light
    /// shows these exactly; Dark shows `neon` of each.
    static let presets: [(hex: String, name: String)] = [
        ("#e67326", "Orange"), ("#ffb800", "Gold"), ("#3ddc84", "Green"), ("#00c2b8", "Teal"),
        ("#2e7dff", "Blue"), ("#662482", "Nostr purple"), ("#ff2d87", "Pink"), ("#a8071a", "Blood red"),
    ]

    static let white: RGB = (255, 255, 255)
    static let cardDark: RGB = (28, 28, 30)
    static let textMin = 4.5 // WCAG body text
    /// Light keeps the exact colour as text at or above this on white; under it, text is darkened to `textMin`.
    static let lightTextKeep = 3.5
    static let labelMin = 3.0 // a bold label on a fill (WCAG large text)

    static func rgb(_ hex: String) -> RGB {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xE67326
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    private static func lin(_ c: Double) -> Double { let x = c / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    private static func unlin(_ c: Double) -> Double { 255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) }

    static func luminance(_ c: RGB) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// OKLab (Björn Ottosson): changing only L keeps the hue and how colourful it looks.
    static func toLab(_ c: RGB) -> (Double, Double, Double) {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }

    private static func fromLab(_ L: Double, _ A: Double, _ B: Double) -> RGB {
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.291485548 * B, 3)
        func ch(_ v: Double) -> Double { (unlin(min(1, max(0, v)))).rounded() }
        return (ch(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                ch(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                ch(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s))
    }

    /// The colour moved lighter (dir 1) or darker (-1) in small steps until it reads at `min` on `bg`.
    static func readable(_ c: RGB, on bg: RGB, min: Double, dir: Double) -> RGB {
        if contrast(c, bg) >= min { return c }
        let (L, A, B) = toLab(c)
        for i in 1...100 {
            let next = fromLab(Swift.min(1, Swift.max(0, L + dir * Double(i) * 0.01)), A, B)
            if contrast(next, bg) >= min { return next }
        }
        return dir < 0 ? (0, 0, 0) : white
    }

    /// `amount` of the picked colour mixed into a paper base, in sRGB, rounded to bytes.
    static func mix(paperHex base: UInt32, pick: String, amount: Double) -> RGB {
        let b: RGB = (Double((base >> 16) & 0xFF), Double((base >> 8) & 0xFF), Double(base & 0xFF))
        let c = rgb(pick)
        func m(_ x: Double, _ y: Double) -> Double { (x * (1 - amount) + y * amount).rounded() }
        return (m(b.r, c.r), m(b.g, c.g), m(b.b, c.b))
    }

    static func shade(_ c: RGB, _ dL: Double) -> RGB {
        let (L, A, B) = toLab(c)
        return fromLab(min(1, max(0, L + dL)), A, B)
    }

    /// White or black for a label on a fill of this colour: true = white, whenever it reads as a bold label.
    static func whiteLabelOn(_ c: RGB) -> Bool { contrast(white, c) >= labelMin }

    static func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", Int(c.r), Int(c.g), Int(c.b)) }

    // MARK: Neon (Dark) — OKLCH: the most chroma sRGB holds at a lightness and hue.

    private static func labRGB(_ L: Double, _ A: Double, _ B: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.291485548 * B, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)
    }

    private static func maxChroma(_ L: Double, _ H: Double) -> Double {
        var lo = 0.0, hi = 0.4
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            let c = labRGB(L, mid * cos(H), mid * sin(H))
            let inside = [c.0, c.1, c.2].allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
            if inside { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Dark mode's neon of a colour: its hue at (nearly) the most chroma sRGB
    /// allows, at the darkest lightness from max(its own, 0.55) up that reads
    /// 4.5:1 on the dark card. Greys have no hue to push, so they only get lighter.
    static func neon(_ c: RGB) -> RGB {
        let (L0, A, B) = toLab(c)
        let C0 = hypot(A, B), H = atan2(B, A)
        if C0 < 0.03 { return readable(c, on: cardDark, min: textMin, dir: 1) }
        let start = Swift.max(L0, 0.55)
        var i = 0
        while start + Double(i) * 0.005 <= 0.95 {
            let L = start + Double(i) * 0.005, mx = maxChroma(L, H)
            let C = Swift.min(mx, Swift.max(C0, mx * 0.97))
            let next = fromLab(L, C * cos(H), C * sin(H))
            if contrast(next, cardDark) >= textMin { return next }
            i += 1
        }
        let mx = maxChroma(0.95, H)
        return fromLab(0.95, mx * cos(H), mx * sin(H))
    }

    // MARK: The accent's colours for both modes

    /// Every accent colour for both modes, from one pick. `fill` is buttons,
    /// rings and borders; `text` is accent text (#tags, links).
    struct Tokens {
        var darkFill: RGB, darkLight: RGB, darkDeep: RGB, darkWhiteLabel: Bool
        var lightFill: RGB, lightText: RGB, lightLight: RGB, lightDeep: RGB, lightWhiteLabel: Bool
    }

    static func tokens(_ pick: RGB) -> Tokens {
        let glow = neon(pick)
        let keep = contrast(pick, white) >= lightTextKeep
        let lift = shade(pick, 0.08)
        let lightEnd = !whiteLabelOn(pick) || contrast(white, lift) >= labelMin ? lift : pick
        return Tokens(darkFill: glow, darkLight: shade(glow, 0.08), darkDeep: shade(glow, -0.12), darkWhiteLabel: whiteLabelOn(glow),
                      lightFill: pick, lightText: keep ? pick : readable(pick, on: white, min: textMin, dir: -1),
                      lightLight: lightEnd, lightDeep: shade(pick, -0.1), lightWhiteLabel: whiteLabelOn(pick))
    }

    /// True when Light darkens the colour for text (under 3.5:1 on white).
    static func textDarkenedInLight(_ c: RGB) -> Bool { contrast(c, white) < lightTextKeep }
}
