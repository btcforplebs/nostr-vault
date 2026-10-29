import XCTest
@testable import MediaLogic

/// DECK-0003 (SNO, kind 33331): the two real objects read and draw, and every
/// §1.9 rule that refuses a payload refuses it with a reason.
final class SnoObjectTests: XCTestCase {

    private func fixtureContent(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(event["kind"] as? Int, SnoObject.kind)
        return try XCTUnwrap(event["content"] as? String)
    }

    private func read(_ json: String) -> Result<SnoObject, SnoObject.Rejection> {
        SnoObject.read(json)
    }

    private func rejection(_ json: String) -> SnoObject.Rejection? {
        if case .failure(let r) = SnoObject.read(json) { return r }
        return nil
    }

    // MARK: Real events

    /// 301fd9f8…, from SNOcrash.art: lines mode, `ticks` a single run of 40.
    func testReadsAJFU() throws {
        let object = try SnoObject.read(fixtureContent("sno-aj-fu")).get()
        XCTAssertEqual(object.name, "AJ FU")
        XCTAssertEqual(object.mode, .lines)
        XCTAssertEqual(object.positions.count, 40)
        XCTAssertEqual(object.faces.count, 69)
        XCTAssertEqual(object.positions[0], SIMD3(-3, 0, 2))
        // Index 116 in cyberspace-neon-256 is #d45a00.
        XCTAssertEqual(object.colors[0], SnoObject.RGB(r: 0xD4, g: 0x5A, b: 0x00))
        let scene = SnoScene(object)
        XCTAssertFalse(scene.edges.isEmpty)
        XCTAssertEqual(Set(scene.edges).count, scene.edges.count, "each edge once")
    }

    /// af59adb7…, from ONOSENDAI: solid, one fine position per vertex.
    func testReadsSilverKeyWithTicks() throws {
        let object = try SnoObject.read(fixtureContent("sno-silver-key")).get()
        XCTAssertEqual(object.mode, .solid)
        XCTAssertEqual(object.positions.count, 32)
        XCTAssertEqual(object.faces.count, 60)
        // vertices[0] [0,0,0] + ticks [6,18,0]/120
        XCTAssertEqual(object.positions[0].x, 0.05, accuracy: 1e-12)
        XCTAssertEqual(object.positions[0].y, 0.15, accuracy: 1e-12)
        let prims = SnoScene(object).primitives(yaw: 0.6, pitch: 0.3, size: 300)
        let triangles = prims.filter { if case .triangle = $0 { return true } else { return false } }
        XCTAssertEqual(triangles.count, 60)
    }

    func testPrimitivesStayInsideTheSquareAtEveryAngle() throws {
        let scene = SnoScene(try SnoObject.read(fixtureContent("sno-silver-key")).get())
        for step in 0..<24 {
            for prim in scene.primitives(yaw: Double(step) * .pi / 12, pitch: 0.5, size: 200) {
                if case .point(let p, _) = prim {
                    XCTAssertTrue((0...200).contains(p.x) && (0...200).contains(p.y), "\(p)")
                }
            }
        }
    }

    // MARK: Small valid payloads

    private let cube = #"{"v":2,"name":"c","unit":0,"mode":"solid","vertices":[[0,0,0],[1,0,0],[0,1,0]],"colors":[7,7,7],"faces":[[0,1,2]]"#

    func testVersionOneNegatesZAndReadsLiteralColors() throws {
        let o = try read(#"{"v":1,"name":"x","unit":0,"mode":"points","vertices":[[0,0,2]],"colors":[[1,0,0.5]],"faces":[]}"#).get()
        XCTAssertEqual(o.positions[0].z, -2)
        XCTAssertEqual(o.colors[0], SnoObject.RGB(r: 255, g: 0, b: 128))
    }

    func testIgnoresTypeAndUnknownFields() throws {
        XCTAssertNoThrow(try read(cube + #","type":"shard","glow":true}"#).get())
    }

    func testFaceColorsRunLength() throws {
        let o = try read(#"{"v":2,"name":"c","unit":0,"mode":"solid","vertices":[[0,0,0],[1,0,0],[0,1,0],[1,1,0]],"colors":[0,0,0,0],"faces":[[0,1,2],[1,3,2]],"facecolors":[9,-1]}"#).get()
        XCTAssertEqual(o.faceColors, [SnoObject.builtInPalette[9], SnoObject.builtInPalette[9]])
    }

    func testInlinePaletteAndPaletteReference() throws {
        let inline = try read(#"{"v":2,"name":"c","unit":0,"mode":"points","vertices":[[0,0,0]],"colors":[1],"faces":[],"palette":[[1,2,3],[4,5,6]]}"#).get()
        XCTAssertEqual(inline.colors[0], SnoObject.RGB(r: 4, g: 5, b: 6))
        // An unfetched reference draws in the built-in (§1.3b).
        let ref = try read(cube + #","palette":"nevent1qqsrq87elpx42dwvq3rjwndwpc6539udtau0vvzvh2ezpwv4pxjz5cq"}"#).get()
        XCTAssertEqual(ref.colors[0], SnoObject.builtInPalette[7])
    }

    func testOpacityIsRepairedNotRefused() throws {
        XCTAssertEqual(try read(cube + #","opacity":5}"#).get().opacity, 0.1)
        XCTAssertEqual(try read(cube + #","opacity":"half"}"#).get().opacity, 1)
        XCTAssertEqual(try read(cube + #","opacity":null}"#).get().opacity, 1)
        XCTAssertEqual(try read(cube + #","extent":999}"#).get().name, "c")
    }

    func testPartsOnlyObjectIsValid() throws {
        let o = try read(#"{"v":2,"name":"p","unit":3,"mode":"solid","vertices":[],"colors":[],"faces":[],"refs":[["a","33331:\#(String(repeating: "a", count: 64)):tile"]],"parts":[[0,240,0,0,0,90,0,-1]]}"#).get()
        XCTAssertEqual(o.parts.count, 1)
        XCTAssertEqual(o.parts[0].at.x, 2)
        XCTAssertFalse(SnoScene(o).primitives(yaw: 0, pitch: 0, size: 100).isEmpty)
    }

    func testLinesWithoutFacesIsAPolyline() throws {
        let o = try read(#"{"v":2,"name":"l","unit":0,"mode":"lines","vertices":[[0,0,0],[1,0,0],[1,1,0]],"colors":[1,2,3],"faces":[]}"#).get()
        XCTAssertEqual(SnoScene(o).edges, [SIMD2(0, 1), SIMD2(1, 2)])
    }

    func testNameIsTruncatedTo64() throws {
        let long = String(repeating: "n", count: 80)
        XCTAssertEqual(try read(#"{"v":2,"name":"\#(long)","unit":0,"mode":"points","vertices":[],"colors":[],"faces":[]}"#).get().name.count, 64)
    }

    // MARK: §1.9 rejections, one per rule

    func testRejectsEachRule() {
        let base = #""name":"c","unit":0,"mode":"solid","vertices":[[0,0,0],[1,0,0],[0,1,0]],"colors":[7,7,7],"faces":[[0,1,2]]"#
        let cases: [(String, SnoObject.Rejection)] = [
            ("[1,2]", .notJSON),
            ("not json", .notJSON),
            (#"{"v":3,"# + base + "}", .version),                                  // 1
            (#"{"v":2,"name":"  ","unit":0,"mode":"solid","vertices":[],"colors":[],"faces":[]}"#, .name),
            (#"{"v":2,"name":"c","unit":0,"mode":"solid","colors":[],"faces":[]}"#, .missing("vertices")), // 2
            (#"{"v":2,"name":"c","unit":0,"mode":"solid","vertices":[[0,0,0]],"colors":[],"faces":[]}"#, .lengthMismatch),
            (#"{"v":2,"name":"c","unit":0,"mode":"wire","vertices":[],"colors":[],"faces":[]}"#, .mode), // 4
            (#"{"v":2,"name":"c","unit":85,"mode":"solid","vertices":[],"colors":[],"faces":[]}"#, .unit), // 5
            (#"{"v":2,"name":"c","unit":0,"mode":"points","vertices":[[0,0.5,0]],"colors":[1],"faces":[]}"#, .vertex(0)), // 6
            (#"{"v":2,"name":"c","unit":0,"mode":"points","vertices":[["0",0,0]],"colors":[1],"faces":[]}"#, .vertex(0)),
            (#"{"v":2,"# + base + #","ticks":[-2]}"#, .ticks),                     // 7
            (#"{"v":2,"# + base + #","ticks":[[0,0,120],-2]}"#, .ticks),
            (#"{"v":2,"# + base + #","ticks":[0,-3]}"#, .ticks),
            (#"{"v":2,"name":"c","unit":0,"mode":"solid","vertices":[[0,0,0],[1,0,0],[0,1,0]],"colors":[7,7,7],"faces":[[0,1,3]]}"#, .face(0)), // 8
            (#"{"v":2,"name":"c","unit":0,"mode":"solid","vertices":[[0,0,0],[1,0,0],[0,1,0]],"colors":[7,7,7],"faces":[[0,1,1]]}"#, .face(0)),
            (#"{"v":2,"# + base + #","palette":"vaporwave"}"#, .palette),          // 8a
            (#"{"v":2,"# + base + #","palette":[[1,2,3]]}"#, .palette),
            (#"{"v":2,"# + base + #","palette":[[1,2,3],[0,0,256]]}"#, .palette),
            (#"{"v":2,"name":"c","unit":0,"mode":"points","vertices":[[0,0,0]],"colors":[256],"faces":[]}"#, .color(0)), // 8b
            (#"{"v":2,"name":"c","unit":0,"mode":"points","vertices":[[0,0,0]],"colors":[2],"faces":[],"palette":[[0,0,0],[1,1,1]]}"#, .color(0)),
            (#"{"v":1,"name":"c","unit":0,"mode":"points","vertices":[[0,0,0]],"colors":[3],"faces":[]}"#, .color(0)),
            (#"{"v":2,"# + base + #","facecolors":[-1]}"#, .faceColors),           // 8c
            (#"{"v":2,"# + base + #","facecolors":[1,2]}"#, .faceColors),
            (#"{"v":2,"# + base + #","facecolors":[300]}"#, .faceColors),
            (#"{"v":2,"# + base + #","up":1}"#, .up),                              // 10
            (#"{"v":2,"# + base + #","spin":360}"#, .spin),
            (#"{"v":2,"# + base + #","refs":[["e","nothex"]]}"#, .refs),           // 11
            (#"{"v":2,"# + base + #","parts":[[0,0,0,0,0,0,0,0]]}"#, .parts),      // 12: parts without refs
            (#"{"v":2,"# + base + #","refs":[["e","\#(String(repeating: "b", count: 64))"]],"parts":[[0,7681,0,0,0,0,0,0]]}"#, .parts),
            (#"{"v":2,"# + base + #","refs":[["e","\#(String(repeating: "b", count: 64))"]],"parts":[[0,0,0,0,0,0,0,-1]]}"#, .parts),
            (#"{"v":2,"# + base + #","ticks":null}"#, .nullField("ticks")),
        ]
        for (json, expected) in cases {
            XCTAssertEqual(rejection(json), expected, json)
        }
        // Every rejection reads as a sentence.
        for (_, r) in cases { XCTAssertFalse(r.reason.isEmpty) }
    }

    func testBuiltInPaletteHas256() {
        XCTAssertEqual(SnoObject.builtInPalette.count, 256)
        XCTAssertEqual(SnoObject.builtInPalette[0], SnoObject.RGB(r: 0x00, g: 0x36, b: 0x32))
    }
}
