import XCTest
import simd
@testable import MediaLogic

final class TrustMapTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    private let author = String(repeating: "a", count: 64)

    private func key(_ n: Int) -> String { String(format: "%064x", n * 0x1234567 + 1) }

    private func list(_ signer: String, tags: [String], at createdAt: Int = 0) -> [String: Any] {
        ["kind": 3, "pubkey": signer, "created_at": createdAt, "tags": tags.map { ["p", $0] }]
    }

    /// Keys spread over all their hex digits, like real ones.
    private func randomKey(_ n: Int) -> String {
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 &* UInt64(n + 1)
        return (0..<4).map { _ -> String in
            h = (h ^ (h >> 31)) &* 0xBF58_476D_1CE4_E5B9
            return String(format: "%016llx", h)
        }.joined()
    }

    func testDirectionComesFromTheKeyAndStaysPut() {
        // Longitude is the leading digits; height is the next eight.
        let front = TrustMap.direction(of: "00000000" + "80000000" + String(repeating: "f", count: 48))
        XCTAssertEqual(front.x, 1, accuracy: 1e-9)
        XCTAssertEqual(front.z, 0, accuracy: 1e-9)
        let pole = TrustMap.direction(of: "40000000" + "ffffffff" + String(repeating: "f", count: 48))
        XCTAssertEqual(pole.z, 1, accuracy: 1e-8)
        for n in 0..<200 {
            let d = TrustMap.direction(of: randomKey(n))
            XCTAssertEqual(simd_length(d), 1, accuracy: 1e-9)
            XCTAssertEqual(d, TrustMap.direction(of: randomKey(n)))
        }
        // Not hex: still stable and on the sphere.
        XCTAssertEqual(TrustMap.direction(of: "not-a-key"), TrustMap.direction(of: "not-a-key"))
        XCTAssertEqual(simd_length(TrustMap.direction(of: "not-a-key")), 1, accuracy: 1e-9)
    }

    func testDirectionsCoverTheWholeSphere() {
        // Even spread: each hemisphere, both ways, holds about half.
        let dirs = (0..<4000).map { TrustMap.direction(of: randomKey($0)) }
        for axis in 0..<3 {
            let up = dirs.filter { $0[axis] > 0 }.count
            XCTAssert((1800...2200).contains(up), "axis \(axis): \(up) of 4000")
        }
    }

    func testHazeIsCappedStableAndKeepsItsPeopleAsTheSetGrows() {
        let small = Set((0..<10).map(randomKey))
        XCTAssertEqual(TrustMap.haze(small, cap: 20), small.sorted())
        let all = Set((0..<6000).map(randomKey))
        let picked = TrustMap.haze(all, cap: 2500)
        XCTAssertEqual(picked.count, 2500)
        XCTAssertEqual(picked, TrustMap.haze(Set(all.shuffled()), cap: 2500))
        // Adding people only swaps out those at the margin: the shell doesn't reshuffle.
        let more = all.union((6000..<6600).map(randomKey))
        let kept = Set(picked).intersection(TrustMap.haze(more, cap: 2500))
        XCTAssertGreaterThan(kept.count, 2100)
    }

    // MARK: Globe camera

    private func flicked() -> GlobeCamera {
        var camera = GlobeCamera()
        camera.flick(vx: 800, vy: -300, at: 0, reduceMotion: false)
        return camera
    }

    private func run(_ camera: inout GlobeCamera, hz: Double, seconds: Double, reduceMotion: Bool = false) {
        let dt = 1 / hz
        var now = 0.0
        for _ in 0..<Int(seconds * hz) {
            now += dt
            camera.step(dt: dt, now: now, reduceMotion: reduceMotion)
        }
    }

    func testSpinFeelsTheSameAt60And120Hz() {
        var at60 = flicked(), at120 = flicked()
        run(&at60, hz: 60, seconds: 1.5)
        run(&at120, hz: 120, seconds: 1.5)
        XCTAssertEqual(simd_length(at60.spin), simd_length(at120.spin), accuracy: 1e-6)
        // Same orientation to within a fraction of a degree.
        let apart = 2 * acos(min(1, abs(simd_dot(at60.orientation.vector, at120.orientation.vector))))
        XCTAssertLessThan(apart, 0.01)
    }

    func testFlickGlidesThenSettles() {
        var camera = flicked()
        run(&camera, hz: 120, seconds: 8)
        XCTAssertEqual(camera.spin, .zero)
    }

    func testFlyToArrivesAndLetsTheClockSleep() {
        var camera = GlobeCamera()
        camera.zoom = 2
        camera.zoomTarget = 2
        let target = GlobeCamera.facing(TrustMap.direction(of: randomKey(7)))
        camera.fly(to: target, at: 0)
        // Arrives (and zooms back out) before the idle drift starts at 3 s.
        run(&camera, hz: 120, seconds: 2.5)
        XCTAssertNil(camera.flyTarget)
        XCTAssertEqual(camera.orientation.vector, target.vector)
        XCTAssertEqual(camera.zoom, 1)
        // Still awake for the idle drift, asleep once idle long enough.
        XCTAssertTrue(camera.wantsFrames(now: 2.5, reduceMotion: false))
        XCTAssertFalse(camera.wantsFrames(now: GlobeCamera.sleepAfter + 1, reduceMotion: false))
    }

    func testIdleDriftStopsBeforeTheClockSleeps() {
        var camera = GlobeCamera()
        var now = 0.0
        while now < GlobeCamera.sleepAfter { now += 1 / 120; camera.step(dt: 1 / 120, now: now, reduceMotion: false) }
        let before = camera.orientation
        camera.step(dt: 1 / 120, now: now + 1 / 120, reduceMotion: false)
        XCTAssertEqual(camera.orientation.vector, before.vector)
    }

    func testReduceMotionCutsInsteadOfGliding() {
        var camera = GlobeCamera()
        camera.flick(vx: 800, vy: 0, at: 0, reduceMotion: true)
        XCTAssertEqual(camera.spin, .zero)
        let target = GlobeCamera.facing(TrustMap.direction(of: randomKey(3)))
        camera.fly(to: target, at: 0)
        camera.step(dt: 1 / 120, now: 1 / 120, reduceMotion: true)
        XCTAssertNil(camera.flyTarget)
        XCTAssertEqual(camera.orientation.vector, target.vector)
        // No idle drift, and nothing keeps the clock awake once still.
        let still = camera.orientation
        camera.step(dt: 1 / 120, now: 5, reduceMotion: true)
        XCTAssertEqual(camera.orientation.vector, still.vector)
        XCTAssertFalse(camera.wantsFrames(now: 5, reduceMotion: true))
    }

    func testAHitchCannotFlingTheGlobe() {
        var smooth = flicked(), hitched = flicked()
        smooth.step(dt: GlobeCamera.maxStep, now: 1, reduceMotion: false)
        hitched.step(dt: 2, now: 1, reduceMotion: false)
        XCTAssertEqual(smooth.orientation.vector, hitched.orientation.vector)
    }

    func testSpreadPicksEvenlyThroughTheList() {
        let keys = (0..<48).map(key)
        XCTAssertEqual(TrustMap.spread(keys, count: 4), [keys[0], keys[12], keys[24], keys[36]])
        XCTAssertEqual(TrustMap.spread(Array(keys.prefix(3)), count: 12), Array(keys.prefix(3)))
        XCTAssertEqual(TrustMap.spread(keys, count: 0), keys)
    }

    func testNextBatchSkipsSeenAndAuthor() {
        let follows = [key(1), key(2), author, key(3)]
        let filters = TrustMap.nextBatch(author: author, follows: follows, seen: [key(2)])
        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(filters[0]["authors"] as? [String], [key(1), key(3)])
        XCTAssertEqual(filters[0]["#p"] as? [String], [author])
        XCTAssertEqual(filters[0]["limit"] as? Int, TrustMap.batchSize)
        XCTAssertTrue(TrustMap.nextBatch(author: author, follows: [key(1), author], seen: [key(1)]).isEmpty)
        // Someone with thousands of follows is asked about in chunks.
        let many = (1...2500).map(key)
        XCTAssertEqual(TrustMap.nextBatch(author: author, follows: many, seen: [], chunkSize: 1000)
            .compactMap { ($0["authors"] as? [String])?.count }, [1000, 1000, 500])
    }

    func testFollowsOfUsesOnlyTheOwnersNewestList() {
        let owner = key(7)
        let lists = [list(owner, tags: [key(1)], at: 100),
                     list(owner, tags: [key(2), key(2), owner, "short"], at: 200),
                     list(key(8), tags: [key(9)], at: 300)]
        XCTAssertEqual(TrustMap.follows(of: owner, in: lists), [key(2)])
        XCTAssertNil(TrustMap.follows(of: key(5), in: lists))
    }

    func testAllBridgesIsUncapped() {
        let follows = Set((1...9).map(key))
        let lists = follows.map { list($0, tags: [author]) }
        let all = TrustPath.allBridges(author: author, me: me, follows: follows, contactLists: lists)
        XCTAssertEqual(all, follows.sorted())
        XCTAssertEqual(TrustPath.resolve(author: author, me: me, follows: follows, trustGraph: ["x"],
                                         contactLists: lists).bridges, Array(all.prefix(5)))
    }

    func testDeeperChains() {
        let bridge = key(1), other = key(2), via = key(3), stranger = key(4)
        let follows: Set<String> = [bridge, other]
        // Seeds: anyone's lists that tag the author. A follow's list is not a
        // middle step (that's 2 hops), and neither is your own.
        let seeds = [list(via, tags: [author]), list(stranger, tags: [author]),
                     list(bridge, tags: [author]), list(me, tags: [author])]
        let viaList = TrustMap.deeperVia(author: author, me: me, follows: follows,
                                         trustGraph: [stranger], seeds: seeds)
        XCTAssertEqual(viaList, [stranger, via], "people in your graph come first")

        let filters = TrustMap.deeperLinkFilters(follows: Array(follows).sorted(), via: viaList)
        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(filters[0]["#p"] as? [String], viaList)

        // A stranger's list can't invent a route; only your follows' lists count.
        let links = [list(bridge, tags: [via, key(9)]), list(other, tags: [stranger, via]),
                     list(key(5), tags: [via])]
        let chains = TrustMap.chains(me: me, follows: follows, via: viaList, links: links)
        XCTAssertEqual(chains, [TrustMap.Chain(bridge: other, via: stranger),
                                TrustMap.Chain(bridge: bridge, via: via),
                                TrustMap.Chain(bridge: other, via: via)].sorted { ($0.via, $0.bridge) < ($1.via, $1.bridge) })
        XCTAssertTrue(TrustMap.deeperLinkFilters(follows: [bridge], via: []).isEmpty)
    }

    func testPickFacesShowsOnlyRenderedPicturesInOrder() {
        let candidates = (1...6).map(key)
        let rendered: Set<String> = [key(2), key(5), key(6)]
        XCTAssertEqual(TrustMap.pickFaces(candidates, renders: rendered.contains, count: 2), [key(2), key(5)])
        XCTAssertEqual(TrustMap.pickFaces(candidates, renders: rendered.contains, count: 10), [key(2), key(5), key(6)])
        XCTAssertEqual(TrustMap.pickFaces(candidates, renders: { _ in false }), [])
    }

    func testFaceCandidatesAreStableAndSpread() {
        let ring = (1...200).map(key)
        let a = TrustMap.faceCandidates(ring.shuffled(), count: 10)
        XCTAssertEqual(a, TrustMap.faceCandidates(ring, count: 10))
        XCTAssertEqual(Set(a).count, 10)
        XCTAssertEqual(TrustMap.faceCandidates([key(3), key(1)]), [key(1), key(3)].sorted())
    }

    func testFaceCandidatesPutTheMostEngagedFirst() {
        let ring = (1...200).map(key)
        let engagement = [key(150): 9, key(7): 4, key(42): 4, key(999): 50]
        let picked = TrustMap.faceCandidates(ring, engagement: engagement, count: 10)
        // Busiest first, ties by key; someone you don't follow never appears.
        XCTAssertEqual(Array(picked.prefix(3)), [key(150), key(7), key(42)])
        XCTAssertEqual(picked.count, 10)
        XCTAssertEqual(Set(picked).count, 10)
        XCTAssertFalse(picked.contains(key(999)))
    }

    func testEngagementScoresCountBothDirections() {
        let me = key(1), alice = key(2), bob = key(3), carol = key(4)
        func ev(_ pubkey: String, _ kind: Int, _ tags: [[String]]) -> [String: Any] {
            ["pubkey": pubkey, "kind": kind, "tags": tags]
        }
        let mine = [
            ev(me, 7, [["e", "x"], ["p", alice]]),               // a like: alice +2
            ev(me, 1, [["p", bob], ["p", alice]]),               // reply in bob's thread to alice: alice +2
            ev(me, 6, [["p", me]]),                              // reposting myself counts for no one
            ev(bob, 7, [["p", carol]]),                          // not mine: ignored
        ]
        let toMe = [
            ev(bob, 7, [["p", me]]),                             // bob liked me: +1
            ev("zapper", 9735, [["p", me], ["P", carol]]),       // carol zapped me: +3
            ev(carol, 1, [["p", alice]]),                        // not aimed at me: ignored
        ]
        let scores = TrustMap.engagementScores(mine: mine, toMe: toMe, me: me)
        XCTAssertEqual(scores, [alice: 4, bob: 1, carol: 3])
    }

    func testSearchPeopleRanksFollowsThenWebThenPrefix() {
        let people = [
            TrustMap.Person(pubkey: key(1), names: ["Alice Stranger"]),
            TrustMap.Person(pubkey: key(2), names: ["Mal Alice"]),
            TrustMap.Person(pubkey: key(3), names: ["alice", "alice@example.com"]),
            TrustMap.Person(pubkey: key(4), names: ["Alicewebber"]),
            TrustMap.Person(pubkey: key(5), names: ["Bob"]),
        ]
        let found = TrustMap.searchPeople(" ALI ", in: people, follows: [key(2), key(3)], web: [key(4)])
        XCTAssertEqual(found, [key(3), key(2), key(4), key(1)])
        XCTAssertTrue(TrustMap.searchPeople("  ", in: people, follows: [], web: []).isEmpty)
        XCTAssertEqual(TrustMap.searchPeople("a", in: people, follows: [], web: [], limit: 2).count, 2)
    }

    func testSeatFacesNeverLetsOneFaceCoverAnother() {
        let spot = { (k: String, x: Double) in TrustMap.FaceSpot(key: k, x: x, y: 0, r: 10) }
        // Front-most first: b sits on a, c is clear, d sits on the core.
        let spots = [spot("a", 0), spot("b", 5), spot("c", 40), spot("d", 100)]
        let core = TrustMap.FaceSpot(key: "core", x: 100, y: 0, r: 20)
        XCTAssertEqual(TrustMap.seatFaces(spots, blocked: [core]), ["a", "c"])
        // A face seated last frame keeps its seat over a newcomer in front.
        XCTAssertEqual(TrustMap.seatFaces(spots, kept: ["b"], blocked: [core]), ["b", "c"])
        // The author always gets a picture.
        XCTAssertEqual(TrustMap.seatFaces(spots, always: ["d"], blocked: [core]), ["a", "c", "d"])
        // A little overlap is fine; covering is not.
        XCTAssertEqual(TrustMap.seatFaces([spot("a", 0), spot("b", 18)]), ["a", "b"])
        XCTAssertEqual(TrustMap.seatFaces([spot("a", 0), spot("b", 16)]), ["a"])
    }

    func testLayerCountsSplitFollowsFromTheRestAndSkipYou() {
        let follows: Set<String> = [me, key(1), key(2)]
        let web: Set<String> = [me, key(1), key(2), key(3), key(4), key(5)]
        let counts = TrustMap.layerCounts(me: me, follows: follows, web: web)
        XCTAssertEqual(counts[.following], 2)
        XCTAssertEqual(counts[.furtherOut], 3)
        XCTAssertEqual(counts[.everyone], 5)
        // A follow the relay hasn't mapped yet still counts as a follow.
        XCTAssertEqual(TrustMap.layerCounts(me: me, follows: [key(9)], web: [])[.everyone], 1)
    }

    func testPickingALayerDimsTheOtherOneWithoutHidingIt() {
        XCTAssertEqual(TrustMap.layerWeights(.everyone), SIMD3(1, 1, 1))
        for layer in [TrustMap.Layer.following, .close, .furtherOut] {
            let w = TrustMap.layerWeights(layer)
            // Every part stays faintly there; only the picked one is bright.
            XCTAssertGreaterThan(simd_reduce_min(w), 0, "\(layer)")
        }
        XCTAssertEqual(TrustMap.layerWeights(.following).x, 1)
        XCTAssertLessThan(TrustMap.layerWeights(.following).y, 0.5)
        XCTAssertGreaterThan(TrustMap.layerWeights(.close).y, 1)
        XCTAssertLessThan(TrustMap.layerWeights(.close).z, 0.5)
        XCTAssertGreaterThan(TrustMap.layerWeights(.furtherOut).z, 1)
        XCTAssertLessThan(TrustMap.layerWeights(.furtherOut).y, 0.5)
    }

    func testCloseSplitsTheWebAtTenVouches() {
        let follows: Set<String> = [key(1)]
        let web: Set<String> = [me, key(1), key(2), key(3), key(4)]
        let vouches = [key(2): 10, key(3): 9, key(4): 3]
        let counts = TrustMap.layerCounts(me: me, follows: follows, web: web, vouches: vouches)
        XCTAssertEqual(counts[.close], 1)
        XCTAssertEqual(counts[.furtherOut], 2)
        XCTAssertEqual(counts[.everyone], 4)
        // An old cache has no vouches: no Close, and Further out is everyone past your follows.
        let old = TrustMap.layerCounts(me: me, follows: follows, web: web)
        XCTAssertNil(old[.close])
        XCTAssertEqual(old[.furtherOut], 3)
        XCTAssertEqual(TrustMap.layers(hasVouches: false), [.everyone, .following, .furtherOut])
        XCTAssertEqual(TrustMap.layers(hasVouches: true), [.everyone, .following, .close, .furtherOut])
    }

    func testVouchesComeFromTheCacheAndAreNilOnAnOldOne() throws {
        let new = Data(#"{"pubkeys":{"a":true},"follows":["b"],"vouches":{"a":12,"c":3}}"#.utf8)
        XCTAssertEqual(TrustMap.vouches(fromCache: new), ["a": 12, "c": 3])
        let old = Data(#"{"pubkeys":{"a":true},"timestamp":1}"#.utf8)
        XCTAssertNil(TrustMap.vouches(fromCache: old))
        XCTAssertNil(TrustMap.vouches(fromCache: Data("not json".utf8)))
    }
}
