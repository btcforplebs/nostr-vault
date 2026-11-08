import Foundation

/// Your space › My devices: whether one of your own devices is on the mesh,
/// and when it last was. NV keeps no per-device sync log, so the evidence is
/// the device's FIPS overlay advert (kind 37195, `d` "fips-overlay-v1"): the
/// engine republishes it about every 30 minutes with a one-hour NIP-40
/// expiration. A device this one is connected to right now (the running
/// engine's peers) is connected whatever the relays say. Pure; the web's
/// `desktop/space/my-devices.js` follows the same rule, tested against
/// Fixtures/MyDevices/status-cases.json.
enum MyDevicesStatus {
    enum State: String, Equatable {
        /// This device's engine is connected to it now.
        case connected
        /// Its advert hasn't expired: its mesh engine is up.
        case online
        /// Its newest advert has expired.
        case offline
        /// No advert found on the finder relays.
        case unknown
        /// The finder relays couldn't be asked.
        case unchecked
    }

    struct Status: Equatable {
        let state: State
        /// When it was last on the mesh (unix seconds), when known.
        let lastSeen: Int?
    }

    static let kind = 37195
    static let advertD = "fips-overlay-v1"
    /// An advert this far in the future is a broken clock, not a fresh one.
    static let skew = 600
    /// An advert without a readable expiration counts for this long.
    static let fallbackTTL = 3600

    struct Advert: Equatable {
        let createdAt: Int
        let tags: [[String]]

        func tag(_ name: String) -> String? { tags.first { $0.count >= 2 && $0[0] == name }?[1] }
    }

    static func status(adverts: [Advert], now: Int, connected: Bool, checked: Bool) -> Status {
        if connected { return Status(state: .connected, lastSeen: now) }
        guard checked else { return Status(state: .unchecked, lastSeen: nil) }
        guard let newest = adverts
            .filter({ $0.tag("d") == advertD && $0.createdAt <= now + skew })
            .max(by: { $0.createdAt < $1.createdAt }) else { return Status(state: .unknown, lastSeen: nil) }
        let live: Bool
        if let exp = newest.tag("expiration").flatMap(Int.init) {
            live = exp > now
        } else {
            live = now - newest.createdAt < fallbackTTL
        }
        return Status(state: live ? .online : .offline, lastSeen: newest.createdAt)
    }

    /// Above the list (Your space and Profile › Mesh › My Devices): being on
    /// the mesh means your posts and media can be fetched from that device,
    /// not just that it is linked (Logen, 2026-11-04).
    static let header = "Devices on your mesh share your posts and media with people who can reach them."
    /// A device that is on the mesh.
    static let sharingLine = "On the mesh · sharing your posts and media"

    /// The row's second line.
    static func line(_ status: Status, now: Date = Date()) -> String {
        let ago = status.lastSeen.map { agoText(Date(timeIntervalSince1970: TimeInterval($0)), now: now) }
        switch status.state {
        case .connected: return "Connected now · sharing your posts and media"
        case .online: return sharingLine
        case .offline: return ago.map { "Offline · last shared \($0)" } ?? "Offline"
        case .unknown: return "Not seen on the mesh lately"
        case .unchecked: return "Couldn't check the mesh"
        }
    }

    /// The My Devices row in iPhone Mesh settings: the running
    /// engine's link first, then the device's advert, so an unreachable
    /// device says when it last shared, as on Android and Your space.
    /// `inReach` is nil while this device's engine is not running. Nil when
    /// there is nothing to say (engine off, relays not asked yet).
    static func settingsRow(inReach: Bool?, status: Status, now: Date = Date()) -> (text: String, on: Bool)? {
        if inReach == true { return (sharingLine, true) }
        switch status.state {
        case .online: return (sharingLine, true)
        case .offline, .unknown: return (line(status, now: now), false)
        case .connected, .unchecked: return inReach == false ? ("Not in reach", false) : nil
        }
    }

    /// "just now", "12 min ago", "3 h ago", "2 d ago".
    static func agoText(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }
}
