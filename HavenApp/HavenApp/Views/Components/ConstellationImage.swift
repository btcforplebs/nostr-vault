import SwiftUI
import CoreGraphics

/// Draws a `Constellation` into a bitmap, once per pubkey and pixel size
/// (the twin of web-vault `constellationUrl`). Draw order and every number
/// come from RESEARCH/NV_CONSTELLATION_AVATAR_SPEC.md: sky, clouds, dust,
/// links, glow, stars, all clipped to the circle. Nothing is fetched.
enum ConstellationImage {
    private static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 600
        return c
    }()

    /// The face for `pubkey` at `size` points, or nil when `pubkey` is not a
    /// 64-character hex key.
    static func image(pubkey: String, size: CGFloat, scale: CGFloat) -> PlatformImage? {
        let hex = pubkey.lowercased()
        let pixels = max(1, Int((size * scale).rounded(.up)))
        let key = "\(hex)|\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let c = Constellation(hex: hex), let cg = render(c, pixels: pixels) else { return nil }
        #if canImport(UIKit)
        let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
        #else
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(pixels) / scale, height: CGFloat(pixels) / scale))
        #endif
        cache.setObject(image, forKey: key)
        return image
    }

    static func render(_ c: Constellation, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        // The spec's 100x100 box, y down like SVG.
        let k = CGFloat(pixels) / 100
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: k, y: -k)
        ctx.addEllipse(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.clip()

        func color(_ hex: String, _ alpha: Double = 1) -> CGColor {
            let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return CGColor(colorSpace: space, components: [CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255,
                                                         CGFloat(v & 0xff) / 255, CGFloat(alpha)])!
        }
        func radial(_ from: CGColor, _ to: CGColor, at center: CGPoint, radius: CGFloat, pad: Bool) {
            guard let g = CGGradient(colorsSpace: space, colors: [from, to] as CFArray, locations: [0, 1]) else { return }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                                   options: pad ? [.drawsAfterEndLocation] : [])
        }
        func dot(_ x: Double, _ y: Double, _ r: Double) {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }

        // 1. Sky: past its radius the edge colour carries on (SVG pad).
        radial(color(c.skyInner), color(c.skyOuter), at: CGPoint(x: 38, y: 32), radius: 78, pad: true)
        // 2. Clouds
        for cl in c.clouds {
            radial(color(cl.color, cl.alpha), color(cl.color, 0), at: CGPoint(x: cl.x, y: cl.y), radius: cl.radius, pad: false)
        }
        // 3. Dust
        ctx.setFillColor(color("#ffffff", 0.45))
        for d in c.dust { dot(d.x, d.y, d.r) }
        // 4. Links
        ctx.setStrokeColor(color(c.line, 0.55))
        ctx.setLineWidth(2.2)
        ctx.setLineCap(.round)
        for l in c.links {
            let a = c.stars[l[0]], b = c.stars[l[1]]
            ctx.beginPath()
            ctx.move(to: CGPoint(x: a.x, y: a.y))
            ctx.addLine(to: CGPoint(x: b.x, y: b.y))
            ctx.strokePath()
        }
        // 5. Glow around the bright star
        let you = c.stars[c.you]
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: you.x - 14, y: you.y - 14, width: 28, height: 28))
        ctx.clip()
        radial(color(c.glow, 0.9), color(c.glow, 0), at: CGPoint(x: you.x, y: you.y), radius: 14, pad: false)
        ctx.restoreGState()
        // 6. Stars
        ctx.setFillColor(color(c.star))
        for (i, s) in c.stars.enumerated() { dot(s.x, s.y, i == c.you ? 5.2 : s.r) }
        return ctx.makeImage()
    }
}

/// The constellation as a SwiftUI view, drawn at this screen's scale.
struct ConstellationFace: View {
    let pubkey: String
    let size: CGFloat
    @Environment(\.displayScale) private var scale

    var body: some View {
        if let image = ConstellationImage.image(pubkey: pubkey, size: size, scale: scale) {
            Image(platformImage: image)
                .resizable()
                .frame(width: size, height: size)
        }
    }
}
