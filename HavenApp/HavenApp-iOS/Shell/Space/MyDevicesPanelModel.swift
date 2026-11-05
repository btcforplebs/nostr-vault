import Foundation

/// The data behind Your space › My devices: the owner's devices from
/// Profile › Mesh › My Devices, and each one's FIPS overlay advert from the
/// finder relays (MyDevicesStatus). Reads only; nothing is published.
@MainActor
final class MyDevicesPanelModel: ObservableObject {
    @Published private(set) var adverts: [String: [MyDevicesStatus.Advert]] = [:]
    /// The finder relays answered the last look (false: none did, or not asked yet).
    @Published private(set) var checked = false
    @Published private(set) var checking = false
    /// One look at a time; one asked for meanwhile waits (MyDevicesCheckGate).
    private var gate = MyDevicesCheckGate()

    /// How often the panel looks again while it is on screen.
    static let refreshEvery: TimeInterval = 300

    func devices(_ config: HavenConfig) -> [MeshDevice] {
        FipsMeshDevices.current(config)
    }

    /// Asks the finder relays for each device's newest advert. Skips a look
    /// made in the last minute for the same devices. Asked while a look is
    /// running, it waits for that one and then looks if the devices changed.
    func refresh(_ devices: [MeshDevice], force: Bool = false) async {
        let hexes = Dictionary(devices.compactMap { d in Bech32.decode(d.npub).map { (d.npub, $0.hexString.lowercased()) } },
                               uniquingKeysWith: { a, _ in a })
        let asked = Set(hexes.values)
        guard !asked.isEmpty else { adverts = [:]; checked = true; return }
        var decision = gate.begin(asked: asked, force: force, now: Date())
        while decision == .wait {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            decision = gate.begin(asked: asked, force: force, now: Date())
        }
        guard decision == .look else { return }
        checking = true
        let relays = FipsMeshSettings.finderRelays.compactMap(URL.init(string:))
        let filter: [String: Any] = ["kinds": [MyDevicesStatus.kind], "authors": Array(asked),
                                     "#d": [MyDevicesStatus.advertD], "limit": 50]
        var answered = false
        let events = await ZapHistoryService.query(filters: [filter], relays: relays, timeout: 6,
                                                   onAnswered: { answered = true })
        var byNpub: [String: [MyDevicesStatus.Advert]] = [:]
        for (npub, hex) in hexes {
            byNpub[npub] = events.compactMap { e in
                guard (e["pubkey"] as? String)?.lowercased() == hex, e["kind"] as? Int == MyDevicesStatus.kind,
                      let at = e["created_at"] as? Int else { return nil }
                return MyDevicesStatus.Advert(createdAt: at, tags: e["tags"] as? [[String]] ?? [])
            }
        }
        adverts = byNpub
        checked = answered || !events.isEmpty
        checking = false
        gate.finish(asked: asked, now: Date())
    }
}
