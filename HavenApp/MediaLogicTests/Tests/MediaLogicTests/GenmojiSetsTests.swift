import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MediaLogic

final class GenmojiSetsTests: XCTestCase {
    let me = String(repeating: "a", count: 64)
    let other = String(repeating: "b", count: 64)

    func testSlug() {
        XCTAssertEqual(GenmojiSets.slug("Happy Cat, wearing a Hat!"), "happy_cat_wearing_a_hat")
        XCTAssertEqual(GenmojiSets.slug("  Crème brûlée  "), "creme_brulee")
        XCTAssertEqual(GenmojiSets.slug("🐱🎩"), "")
        XCTAssertEqual(GenmojiSets.slug("a very long description that goes on and on forever"), "a_very_long_description_that_goe")
        XCTAssertEqual(GenmojiSets.slug("abcdefghijklmnopqrstuvwxyz12345 x"), "abcdefghijklmnopqrstuvwxyz12345")
    }

    func testShortcodeUniqueAndFallback() {
        XCTAssertEqual(GenmojiSets.shortcode(for: "Cat hat", taken: []), "cat_hat")
        XCTAssertEqual(GenmojiSets.shortcode(for: "Cat hat", taken: ["cat_hat"]), "cat_hat_2")
        XCTAssertEqual(GenmojiSets.shortcode(for: "Cat hat", taken: ["cat_hat", "cat_hat_2"]), "cat_hat_3")
        XCTAssertEqual(GenmojiSets.shortcode(for: "🐱", taken: []), "genmoji")
        XCTAssertTrue(CustomEmoji.isValidShortcode(GenmojiSets.shortcode(for: "Crème — brûlée!", taken: [])))
    }

    func testProblem() {
        XCTAssertNil(GenmojiSets.problem(shortcode: "cat_hat", taken: []))
        XCTAssertNotNil(GenmojiSets.problem(shortcode: "", taken: []))
        XCTAssertNotNil(GenmojiSets.problem(shortcode: "cat hat", taken: []))
        XCTAssertNotNil(GenmojiSets.problem(shortcode: "cat-hat", taken: []))
        XCTAssertNotNil(GenmojiSets.problem(shortcode: "cat", taken: ["cat"]))
    }

    func testTargetsDefaultFirstAndOnlyOwn() {
        let mine = EmojiLibrary.EmojiSet(address: "30030:\(me):pets", title: "Pets", emojis: [])
        let theirs = EmojiLibrary.EmojiSet(address: "30030:\(other):x", title: "X", emojis: [])
        XCTAssertEqual(GenmojiSets.targets(sets: [theirs, mine], me: me), [
            .init(d: "nv-genmoji", title: "My Genmoji", exists: false),
            .init(d: "pets", title: "Pets", exists: true),
        ])
        let def = EmojiLibrary.EmojiSet(address: "30030:\(me):nv-genmoji", title: "renamed elsewhere", emojis: [])
        XCTAssertEqual(GenmojiSets.targets(sets: [mine, def], me: me).map(\.d), ["nv-genmoji", "pets"])
        XCTAssertEqual(GenmojiSets.targets(sets: [mine, def], me: me)[0].exists, true)
    }

    func testNewSetD() {
        XCTAssertEqual(GenmojiSets.newSetD(title: "Pets & Friends", taken: []), "nv-genmoji-pets_friends")
        XCTAssertEqual(GenmojiSets.newSetD(title: "Pets", taken: ["nv-genmoji-pets"]), "nv-genmoji-pets_2")
        XCTAssertEqual(GenmojiSets.newSetD(title: "🐶", taken: []), "nv-genmoji-set")
        XCTAssertNotEqual(GenmojiSets.newSetD(title: "", taken: []), GenmojiSets.defaultD)
    }

    func testSetTagsNewSet() {
        let e = CustomEmoji(shortcode: "cat_hat", url: "https://m.example/abc.png")
        XCTAssertEqual(GenmojiSets.setTags(base: nil, d: "nv-genmoji", title: "My Genmoji", adding: e), [
            ["d", "nv-genmoji"], ["title", "My Genmoji"], ["image", "https://m.example/abc.png"],
            ["emoji", "cat_hat", "https://m.example/abc.png"],
        ])
    }

    func testSetTagsMergeKeepsEverything() {
        let base = [["d", "nv-genmoji"], ["title", "Mine"], ["image", "https://m.example/first.png"],
                    ["emoji", "a", "https://m.example/a.png"], ["client", "other"], ["unknown", "x", "y"]]
        let e = CustomEmoji(shortcode: "b", url: "https://m.example/b.png")
        let out = GenmojiSets.setTags(base: base, d: "nv-genmoji", title: "My Genmoji", adding: e)
        XCTAssertEqual(out, base + [["emoji", "b", "https://m.example/b.png"]])
        // The same emoji again changes nothing.
        XCTAssertEqual(GenmojiSets.setTags(base: out, d: "nv-genmoji", title: "My Genmoji", adding: e), out)
    }

    func testIsPublicURL() {
        XCTAssertTrue(GenmojiSets.isPublicURL("https://blossom.example.com/abc.png"))
        XCTAssertFalse(GenmojiSets.isPublicURL("http://blossom.example.com/abc.png"))
        XCTAssertFalse(GenmojiSets.isPublicURL("https://npub1xyz.fips/abc.png"))
        XCTAssertFalse(GenmojiSets.isPublicURL("https://localhost:3355/abc.png"))
        XCTAssertFalse(GenmojiSets.isPublicURL("https://127.0.0.1/abc.png"))
        XCTAssertFalse(GenmojiSets.isPublicURL("https://192.168.1.5/abc.png"))
        XCTAssertFalse(GenmojiSets.isPublicURL("https://[::1]/abc.png"))
    }

    func testTakenShortcodes() {
        var lib = EmojiLibrary()
        lib.single = [CustomEmoji(shortcode: "x", url: "https://m.example/x.png")]
        lib.sets = [.init(address: "30030:\(me):s", title: "S", emojis: [CustomEmoji(shortcode: "y", url: "https://m.example/y.png")])]
        XCTAssertEqual(GenmojiSets.takenShortcodes(lib), ["x", "y"])
    }

    func testSaveLabelSaysPublic() {
        XCTAssertTrue(GenmojiSets.saveLabel(setTitle: "My Genmoji").lowercased().contains("public"))
    }

    // MARK: Image

    /// A two-frame HEIC (16 and 64 px, transparent corner): the PNG is the 64 px one, alpha kept.
    func testLargestFramePNG() throws {
        func frame(_ side: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: side / 2, y: side / 2, width: side / 2, height: side / 2))
            return ctx.makeImage()!
        }
        let heic = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(heic, UTType.heic.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(dest, frame(16), nil)
        CGImageDestinationAddImage(dest, frame(64), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let png = try XCTUnwrap(GenmojiImage.largestFramePNG(heic as Data))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64)
        XCTAssertNotEqual(image.alphaInfo, .none)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipLast)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipFirst)
    }

    func testLargestFramePNGRejectsNonImage() {
        XCTAssertNil(GenmojiImage.largestFramePNG(Data("not an image".utf8)))
    }
}
