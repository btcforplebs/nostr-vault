import XCTest
import CryptoKit
@testable import MediaLogic

/// The iOS FIPS mesh photo reader (NIP-F1): which photos it may read, from
/// which vault, and what it does with bytes it cannot trust.
final class MeshMediaRouterTests: XCTestCase {
    private let vault = "npub1" + String(repeating: "q", count: 58)
    private let other = "npub1" + String(repeating: "p", count: 58)
    private let author = String(repeating: "a", count: 64)
    private let photo = Data("a photo that came from the author's phone, long enough to matter".utf8)
    private var sha: String { SHA256.hash(data: photo).map { String(format: "%02x", $0) }.joined() }
    private let base = URL(string: "http://127.0.0.1:41234/0123456789abcdef")!

    // MARK: - Plan

    func testAFipsURLNamesItsVaultAndGoesToTheMeshFirst() {
        let plan = MeshMediaRouter.plan(url: URL(string: "http://\(vault).fips/\(sha).jpg")!, imetaSha256: nil)
        XCTAssertEqual(plan, .init(sha256: sha, hostNpub: vault))
        XCTAssertEqual(plan?.meshFirst, true)
        let upper = MeshMediaRouter.plan(url: URL(string: "http://\(vault.uppercased()).FIPS/\(sha.uppercased())")!, imetaSha256: nil)
        XCTAssertEqual(upper, .init(sha256: sha, hostNpub: vault))
    }

    func testABlossomURLKeepsItsServerFirst() {
        let plan = MeshMediaRouter.plan(url: URL(string: "https://blossom.band/\(sha).png")!, imetaSha256: nil)
        XCTAssertEqual(plan, .init(sha256: sha, hostNpub: nil))
        XCTAssertEqual(plan?.meshFirst, false)
    }

    func testImetaXOnlySpeaksForAURLWithNoHash() {
        let other = String(repeating: "b", count: 64)
        XCTAssertEqual(MeshMediaRouter.plan(url: URL(string: "https://cdn.example/p/photo.jpg")!, imetaSha256: sha),
                       .init(sha256: sha, hostNpub: nil, hashFromPath: false))
        XCTAssertEqual(MeshMediaRouter.plan(url: URL(string: "https://blossom.band/\(sha).jpg")!, imetaSha256: other)?.sha256, sha,
                       "the path hash is what the URL names")
        XCTAssertNil(MeshMediaRouter.plan(url: URL(string: "https://cdn.example/p/photo.jpg")!, imetaSha256: nil))
        XCTAssertNil(MeshMediaRouter.plan(url: URL(string: "https://cdn.example/p/photo.jpg")!, imetaSha256: "not-a-hash"))
    }

    func testOnlyAnNpubHostIsAVault() {
        XCTAssertNil(MeshMediaRouter.meshNpub(inHost: "npub1short.fips"))
        XCTAssertNil(MeshMediaRouter.meshNpub(inHost: "\(vault).fips.evil.com"))
        XCTAssertNil(MeshMediaRouter.meshNpub(inHost: "blossom.band"))
        XCTAssertNil(MeshMediaRouter.meshNpub(inHost: nil))
        XCTAssertNil(MeshMediaRouter.plan(url: URL(string: "http://npub1short.fips/\(sha)")!, imetaSha256: nil)?.hostNpub)
    }

    func testTheListedVaultsAreAskedInOrderAtMostThree() {
        let plain = MeshMediaRouter.Plan(sha256: sha, hostNpub: nil)
        XCTAssertEqual(MeshMediaRouter.vaults(for: plain, serverList: ["https://blossom.band/", "fipsmesh://\(vault)/", "fipsmesh://\(other)/"]), [vault, other])
        let four = ["q", "p", "z", "r"].map { "npub1" + String(repeating: $0, count: 58) }
        XCTAssertEqual(MeshMediaRouter.vaults(for: plain, serverList: four.map { "fipsmesh://\($0)/" }), Array(four.prefix(3)),
                       "web MAX_VAULTS")
        XCTAssertEqual(MeshMediaRouter.vaults(for: plain, serverList: ["https://blossom.band/", "fipsmesh://\(vault)/x"]), [])
    }

    func testAFipsHostCountsOnlyWhenTheAuthorListsIt() {
        let fips = MeshMediaRouter.Plan(sha256: sha, hostNpub: other)
        XCTAssertEqual(MeshMediaRouter.vaults(for: fips, serverList: ["fipsmesh://\(vault)/", "fipsmesh://\(other)/"]), [other])
        XCTAssertEqual(MeshMediaRouter.vaults(for: fips, serverList: ["fipsmesh://\(vault)/"]), [],
                       "a URL naming someone else's node is not the author's vault")
        XCTAssertEqual(MeshMediaRouter.vaults(for: fips, serverList: []), [])
    }

    func testANoteOnlyVouchesForItsOwnImetaHashes() {
        let tags = [["imeta", "url https://cdn.example/a.jpg", "x \(sha.uppercased())", "m image/jpeg"],
                    ["imeta", "url https://cdn.example/b.jpg", "x nope"],
                    ["imeta", "x \(sha)"],
                    ["p", sha]]
        XCTAssertEqual(MeshMediaRouter.imetaSha256s(tags: tags), ["https://cdn.example/a.jpg": sha])
        XCTAssertEqual(MeshMediaRouter.blobCacheKey(sha256: sha).absoluteString, "fipsmesh-blob:\(sha)")
        XCTAssertNotEqual(MeshMediaRouter.blobCacheKey(sha256: sha), URL(string: "https://cdn.example/a.jpg"))
    }

    // MARK: - Reading

    func testAFollowedAuthorsFipsPhotoIsReadFromTheVaultTheURLNames() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(other)/", "fipsmesh://\(vault)/"]])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: vault), author: author)
        XCTAssertEqual(data, photo)
        let state = await fake.snapshot()
        XCTAssertEqual(state.dials, [vault], "the listed vault the URL names, not the first listed")
        XCTAssertEqual(state.gets, [base.appendingPathComponent(sha)])
    }

    func testAFipsURLNamingANodeTheAuthorDoesNotListIsNeverDialled() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: other), author: author)
        XCTAssertNil(data)
        let state = await fake.snapshot()
        XCTAssertEqual(state.dials, [], "dialling would hand that node this device's address")
        XCTAssertEqual(state.gets, [])
    }

    func testSomeoneNotFollowedIsNeverDialled() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        let router = MeshMediaRouter(fake.deps(follows: []))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: vault), author: author)
        XCTAssertNil(data)
        let state = await fake.snapshot()
        XCTAssertEqual(state.dials, [])
        XCTAssertEqual(state.gets, [])
    }

    func testTheLookupIsAnnouncedOnlyForAnAuthorTheMeshMayAsk() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        let lookups = Counter()
        let followed = MeshMediaRouter(fake.deps(follows: [author]))
        _ = await followed.read(plan: .init(sha256: sha, hostNpub: nil), author: author, onLookup: { await lookups.bump() })
        let afterFollowed = await lookups.value
        XCTAssertEqual(afterFollowed, 1, "a followed author's photo says it is loading over FIPS")
        let stranger = MeshMediaRouter(fake.deps(follows: []))
        _ = await stranger.read(plan: .init(sha256: sha, hostNpub: nil), author: author, onLookup: { await lookups.bump() })
        let afterStranger = await lookups.value
        XCTAssertEqual(afterStranger, 1, "no spinner for a read that never starts")
    }

    func testAFailedLoadSaysWhatTheWebSays() {
        XCTAssertEqual(MeshMediaPhase.failed(after: .meshLookup, meshOnly: false), .unreached)
        XCTAssertEqual(MeshMediaPhase.failed(after: .meshLookup, meshOnly: true), .unreached)
        XCTAssertEqual(MeshMediaPhase.failed(after: .loading, meshOnly: true), .notReachable)
        XCTAssertEqual(MeshMediaPhase.failed(after: .loading, meshOnly: false), .notFound)
        XCTAssertEqual(MeshMediaPhase.meshLookup.text(), "Loading image over the mesh…", "web-vault MediaImage.jsx LOADING_TEXT")
        XCTAssertEqual(MeshMediaPhase.unreached.text(), "Couldn't reach the owner's vault", "web-vault UNREACHED_TEXT")
        XCTAssertEqual(MeshMediaPhase.notReachable.text(), "Photo not reachable")
        XCTAssertEqual(MeshMediaPhase.meshLookup.text(video: true), "Loading video over the mesh…")
        XCTAssertNil(MeshMediaPhase.loading.text())
    }

    func testAPlainURLUsesTheAuthorsListedVault() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["https://blossom.band/", "fipsmesh://\(other)/"]])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: nil), author: author)
        XCTAssertEqual(data, photo)
        let dials = await fake.snapshot().dials
        XCTAssertEqual(dials, [other])
    }

    func testNoVaultListedMeansNoDial() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["https://blossom.band/"]])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: nil), author: author)
        XCTAssertNil(data)
        let state = await fake.snapshot()
        XCTAssertEqual(state.dials, [])
        XCTAssertEqual(state.requests, 0, "a list was seen; it just has no vault")
    }

    func testAMissingListIsAskedForOnceAndWaitedOn() async {
        let fake = Fake(photo: photo, base: base)
        await fake.listArrivesAfterRequest(author, ["fipsmesh://\(vault)/"], afterPolls: 3)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: nil), author: author)
        XCTAssertEqual(data, photo, "the first photo of a new follow still loads")
        let requests = await fake.snapshot().requests
        XCTAssertEqual(requests, 1)
    }

    func testAListThatNeverComesIsNotAskedForAgainAtOnce() async {
        let fake = Fake(photo: photo, base: base)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let plan = MeshMediaRouter.Plan(sha256: sha, hostNpub: nil)
        _ = await router.read(plan: plan, author: author)
        _ = await router.read(plan: plan, author: author)
        var state = await fake.snapshot()
        XCTAssertEqual(state.requests, 1)
        XCTAssertEqual(state.sleeps, 12, "only the read that asked waited, and only ~6 s")
        await fake.advance(MeshMediaRouter.requestRetry + 1)
        _ = await router.read(plan: plan, author: author)
        state = await fake.snapshot()
        XCTAssertEqual(state.requests, 2)
    }

    func testWrongBytesDropTheVaultForTheSession() async {
        let fake = Fake(photo: Data("not the photo".utf8), base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let plan = MeshMediaRouter.Plan(sha256: sha, hostNpub: vault)
        let first = await router.read(plan: plan, author: author)
        XCTAssertNil(first)
        await fake.setPhoto(photo)
        let second = await router.read(plan: plan, author: author)
        XCTAssertNil(second, "a distrusted vault is not asked again")
        let state = await fake.snapshot()
        XCTAssertEqual(state.gets.count, 1)
        XCTAssertEqual(state.dials.count, 1)
    }

    func testAMissingOrOversizedBlobKeepsTheVaultsStanding() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let plan = MeshMediaRouter.Plan(sha256: sha, hostNpub: vault)
        await fake.setStatus(404)
        let missing = await router.read(plan: plan, author: author)
        XCTAssertNil(missing)
        await fake.setOversized(true)
        await fake.setStatus(200)
        let tooBig = await router.read(plan: plan, author: author)
        XCTAssertNil(tooBig)
        await fake.setOversized(false)
        let data = await router.read(plan: plan, author: author)
        XCTAssertEqual(data, photo)
        let state = await fake.snapshot()
        XCTAssertEqual(state.gets.count, 3)
        XCTAssertEqual(state.dials.count, 1, "one dial, reused")
        XCTAssertEqual(state.maxBytes, MeshMediaRouter.maxBytes)
    }

    func testPhotosFromOneVaultShareOneDial() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]], dialDelayPolls: 5)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let plan = MeshMediaRouter.Plan(sha256: sha, hostNpub: vault)
        async let a = router.read(plan: plan, author: author)
        async let b = router.read(plan: plan, author: author)
        async let c = router.read(plan: plan, author: author)
        let results = await [a, b, c]
        XCTAssertEqual(results, [photo, photo, photo])
        let dials = await fake.snapshot().dials
        XCTAssertEqual(dials, [vault])
    }

    func testADeadVaultCostsOneWaitThenIsTriedAgainLater() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        await fake.setDialFails(true)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let plan = MeshMediaRouter.Plan(sha256: sha, hostNpub: vault)
        _ = await router.read(plan: plan, author: author)
        _ = await router.read(plan: plan, author: author)
        var dials = await fake.snapshot().dials
        XCTAssertEqual(dials.count, 1)
        await fake.setDialFails(false)
        await fake.advance(MeshMediaRouter.ingressRetry + 1)
        let data = await router.read(plan: plan, author: author)
        XCTAssertEqual(data, photo)
        dials = await fake.snapshot().dials
        XCTAssertEqual(dials.count, 2)
    }

    func testAConnectionResetBeforeTheRouteIsUpIsTriedAgainAndLoads() async {
        // Logen's own photo, 10-22: the engine had just started, the first
        // read went out before the route to his vault was found, the
        // connection was reset and the app said "Couldn't reach the owner's
        // vault" at once, while the web retried and loaded it.
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        await fake.setGetFailures(2)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: vault), author: author)
        XCTAssertEqual(data, photo, "same patience as the web: the third try gets the photo")
        let state = await fake.snapshot()
        XCTAssertEqual(state.gets.count, 3)
        XCTAssertEqual(state.dials.count, 3, "each retry dials again: the old loopback base may be dead")
        XCTAssertEqual(state.sleeps, 2)
    }

    func testAPhotoThatLeftTheScreenStopsAskingAndLeavesTheVaultStanding() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        await fake.setGetFailures(.max)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let plan = MeshMediaRouter.Plan(sha256: sha, hostNpub: vault)
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await router.read(plan: plan, author: author)
        }
        let gone = await read.value
        XCTAssertNil(gone)
        let gets = await fake.snapshot().gets.count
        XCTAssertEqual(gets, 1, "no retries for a photo nobody shows")
        await fake.setGetFailures(0)
        let data = await router.read(plan: plan, author: author)
        XCTAssertEqual(data, photo, "a cancelled read is not the vault's fault")
    }

    func testAPhotoTheFirstListedVaultDoesNotHaveComesFromTheNext() async {
        // Logen's own photo, 10-22: his 10063 lists two mesh vaults; the first
        // is up but never had the photo (404), his Mac (second) has it. The app
        // asked only the first and said "Couldn't reach"; the web loaded it.
        let fake = Fake(photo: photo, base: base, lists: [author: ["https://blossom.band/", "fipsmesh://\(other)/", "fipsmesh://\(vault)/"]])
        await fake.setMissing([other])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: nil), author: author)
        XCTAssertEqual(data, photo)
        let state = await fake.snapshot()
        XCTAssertEqual(state.dials, [other, vault])
        XCTAssertEqual(state.gets.count, 2, "a 404 is an answer: no retries on that vault")
    }

    func testAVaultThatNeverAnswersHandsThePhotoToTheNextAfterItsPatience() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(other)/", "fipsmesh://\(vault)/"]])
        await fake.setDialFails(true, for: other)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let data = await router.read(plan: .init(sha256: sha, hostNpub: nil), author: author)
        XCTAssertEqual(data, photo)
        let dials = await fake.snapshot().dials
        XCTAssertEqual(dials, [other, vault])
    }

    func testOnePhotoGivesUpAcrossAllItsVaultsAfterTheWebsPhotoPatience() async {
        let three = ["q", "p", "z"].map { "npub1" + String(repeating: $0, count: 58) }
        let fake = Fake(photo: photo, base: base, lists: [author: three.map { "fipsmesh://\($0)/" }])
        await fake.setGetFailures(.max)
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let start = await fake.time()
        let data = await router.read(plan: .init(sha256: sha, hostNpub: nil), author: author)
        XCTAssertNil(data)
        let waited = await fake.time().timeIntervalSince(start)
        XCTAssertEqual(waited, MeshMediaRouter.photoPatience, accuracy: 1)
        let dials = Set(await fake.snapshot().dials)
        XCTAssertEqual(dials, Set(three.prefix(2)), "no third vault past the photo's patience")
    }

    func testAVaultThatNeverAnswersIsGivenUpAfterTheWebsPatienceThenBacksOff() async {
        let fake = Fake(photo: photo, base: base, lists: [author: ["fipsmesh://\(vault)/"]])
        let router = MeshMediaRouter(fake.deps(follows: [author]))
        let plan = MeshMediaRouter.Plan(sha256: sha, hostNpub: vault)
        await fake.setGetFailures(.max)
        let start = await fake.time()
        let failed = await router.read(plan: plan, author: author)
        XCTAssertNil(failed)
        let waited = await fake.time().timeIntervalSince(start)
        XCTAssertEqual(waited, MeshMediaRouter.readPatience, accuracy: 1)
        await fake.setGetFailures(0)
        let dialsBefore = await fake.snapshot().dials.count
        let soon = await router.read(plan: plan, author: author)
        XCTAssertNil(soon, "a vault that dials but never answers is not dialled per photo")
        var dials = await fake.snapshot().dials
        XCTAssertEqual(dials.count, dialsBefore)
        await fake.advance(MeshMediaRouter.ingressRetry + 1)
        let data = await router.read(plan: plan, author: author)
        XCTAssertEqual(data, photo)
        dials = await fake.snapshot().dials
        XCTAssertEqual(dials.count, dialsBefore + 1)
    }
}

/// The app around the router: follows, 10063s, the mesh engine and the vault.
private actor Fake {
    struct Snapshot {
        var dials: [String]
        var gets: [URL]
        var listLookups: Int
        var requests: Int
        var sleeps: Int
        var maxBytes: Int?
    }

    private var photo: Data
    private let base: URL
    private var lists: [String: [String]]
    private var pending: [String: (list: [String], afterPolls: Int)] = [:]
    private var status = 200
    private var oversized = false
    private var dialFails = false
    private var deadVaults: Set<String> = []
    private var missing: Set<String> = []
    private var lastDial: String?
    private var getFailures = 0
    private let dialDelayPolls: Int
    private let clock = TestClock()
    private var state = Snapshot(dials: [], gets: [], listLookups: 0, requests: 0, sleeps: 0)

    init(photo: Data, base: URL, lists: [String: [String]] = [:], dialDelayPolls: Int = 0) {
        self.photo = photo
        self.base = base
        self.lists = lists
        self.dialDelayPolls = dialDelayPolls
    }

    func snapshot() -> Snapshot { state }
    func setPhoto(_ data: Data) { photo = data }
    func setStatus(_ code: Int) { status = code }
    func setOversized(_ on: Bool) { oversized = on }
    func setDialFails(_ on: Bool) { dialFails = on }
    func setDialFails(_ on: Bool, for npub: String) { if on { deadVaults.insert(npub) } else { deadVaults.remove(npub) } }
    /// Vaults that are up but answer 404 for the photo.
    func setMissing(_ npubs: Set<String>) { missing = npubs }
    func setGetFailures(_ count: Int) { getFailures = count }
    func time() -> Date { clock.now }
    func advance(_ seconds: TimeInterval) { clock.advance(seconds) }

    func listArrivesAfterRequest(_ author: String, _ list: [String], afterPolls: Int) {
        pending[author] = (list, afterPolls)
    }

    func serverList(_ author: String) -> [String]? {
        state.listLookups += 1
        return lists[author]
    }

    func request(_ author: String) {
        state.requests += 1
    }

    func slept(_ duration: Duration) {
        state.sleeps += 1
        clock.advance(TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18)
        for (author, entry) in pending where state.requests > 0 {
            if entry.afterPolls <= 1 {
                lists[author] = entry.list
                pending[author] = nil
            } else {
                pending[author] = (entry.list, entry.afterPolls - 1)
            }
        }
    }

    func dial(_ npub: String) async -> URL? {
        state.dials.append(npub)
        lastDial = npub
        // Let the other reads queue up behind this dial.
        for _ in 0..<dialDelayPolls { await Task.yield() }
        return dialFails || deadVaults.contains(npub) ? nil : base
    }

    func get(_ url: URL, maxBytes: Int) -> MeshMediaRouter.Reply? {
        state.gets.append(url)
        state.maxBytes = maxBytes
        if getFailures > 0 {
            getFailures -= 1
            return nil
        }
        // Reads here run one at a time: the GET goes to the vault just dialled.
        if let lastDial, missing.contains(lastDial) { return .init(status: 404, data: Data()) }
        return .init(status: status, data: oversized ? nil : photo)
    }

    nonisolated func deps(follows: Set<String>) -> MeshMediaRouter.Dependencies {
        MeshMediaRouter.Dependencies(
            mayDial: { follows.contains($0) },
            serverList: { await self.serverList($0) },
            requestServerList: { await self.request($0) },
            ingress: { await self.dial($0) },
            get: { await self.get($0, maxBytes: $1) },
            now: { [clock] in clock.now },
            sleep: { await self.slept($0) }
        )
    }
}

/// The router reads the time synchronously.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
