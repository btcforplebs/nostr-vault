import Foundation
import Combine

#if os(macOS)
/// One own device public on the web (multi-Mac rules §3.3, Logen's pick 2,
/// Tron #1997 M2). Turning Public on the web on while another own Mac has
/// it asks first; yes moves the owner's lists in one go (10002, 10050 and
/// 10063: the other Mac's entry becomes this one's, in its place). The old
/// Mac sees lists that now name another own device and turns its own switch
/// off. The lists are the one source of truth: nothing else is sent between
/// the Macs, and the account's lists are signed as any list edit is.
@MainActor
final class WebRoleService {
    static let shared = WebRoleService()

    /// The other own device public on the web now.
    struct WebDevice: Equatable {
        let npub: String
        let name: String
        let host: String
    }

    private var listSink: AnyCancellable?
    /// When this Mac took the role: until a list names it, the list still
    /// naming the old Mac is the one from before the move, not a stand-down.
    private var movedHereAt: Date?
    static let moveSettleWindow: TimeInterval = 15 * 60

    /// Watches the owner's server list for the stand-down. Once, at launch.
    func start() {
        guard listSink == nil else { return }
        listSink = NostrService.shared.$serverLists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lists in self?.standDownIfMoved(lists) }
    }

    private var ownNpub: String? {
        MacFipsMeshService.shared.ownNpub ?? MacFipsMeshService.meshNpubFromKey()
    }

    private func ownerServerList(_ lists: [String: [String]]) -> [String] {
        let owner = Bech32.decode(ConfigService.shared.config.ownerNpub)?.hexString.lowercased() ?? ""
        return lists[owner] ?? []
    }

    /// Each own device's domain by mesh npub, this Mac's own included.
    private func domains() -> [String: String] {
        var out = MeshCopyV2Service.peerDomains()
        let mine = ConfigService.shared.config.webDomainForOwnDevices
        if let own = ownNpub, !mine.isEmpty { out[own] = mine }
        return out
    }

    /// The own device other than this Mac that the owner's lists name as
    /// public on the web, or nil (none, or this one).
    func otherWebDevice() -> WebDevice? {
        let doms = domains()
        guard let web = YourDevicesLogic.webDevice(serverList: ownerServerList(NostrService.shared.serverLists), domains: doms, prefer: ownNpub),
              web != ownNpub, let host = doms[web].flatMap(YourDevicesLogic.host) else { return nil }
        let name = ConfigService.shared.config.meshDevices.first { $0.npub == web }?.displayName ?? "your other Mac"
        return WebDevice(npub: web, name: name, host: host)
    }

    /// "Move public web from <A> to <this Mac>?", or nil when nothing to ask.
    func movePrompt(for other: WebDevice) -> String? {
        YourDevicesLogic.moveWebPrompt(current: other.npub, currentName: other.name,
                                       this: ownNpub ?? "", thisName: Host.current().localizedName ?? "this Mac")
    }

    /// The one republish once the owner said yes: `other`'s entries become
    /// this Mac's in the relay list, the DM inbox and the server list.
    /// Called with Public on the web already on here.
    func moveHere(from other: WebDevice, done: @escaping @MainActor (String?) -> Void) {
        let config = ConfigService.shared.config
        guard config.listsOwnDomain, !config.sanitizedRelayURL.isEmpty else { done(nil); return }
        let nostr = NostrService.shared
        nostr.publishOwnerRelayListWebMove(fromHost: other.host, to: config.nostrURL, done: done)
        nostr.publishOwnerDMInboxWebMove(fromHost: other.host, to: config.ownHavenDMInboxURL, done: done)
        movedHereAt = Date()
        nostr.publishServerList(webMove: (fromHost: other.host, to: config.webURL))
    }

    /// The old web device: lists that name another own device turn this
    /// one's switch off, and its domain comes off the relay list and DM inbox
    /// if a list still has it (both no-ops after a move, which swapped it).
    private func standDownIfMoved(_ lists: [String: [String]]) {
        let configService = ConfigService.shared
        let config = configService.config
        let on = config.publicOnWeb ?? !config.isLocal
        guard let own = ownNpub else { return }
        if let moved = movedHereAt {
            if YourDevicesLogic.webDevice(serverList: ownerServerList(lists), domains: domains(), prefer: own) == own
                || Date().timeIntervalSince(moved) > Self.moveSettleWindow {
                movedHereAt = nil
            } else {
                return
            }
        }
        guard YourDevicesLogic.standsDown(publicOnWeb: on, ownNpub: own, serverList: ownerServerList(lists), domains: domains()) else { return }
        let oldInbox = config.ownHavenDMInboxURL
        let relay = config.nostrURL
        let wasListed = config.listsOwnDomain
        configService.config.publicOnWeb = false
        configService.save()
        MeshDiagnostics.log("Public on the web: another of your Macs is the web device now; turned off here")
        if wasListed {
            NostrService.shared.publishOwnerRelayListDrop(relay)
        }
        if !oldInbox.isEmpty {
            NostrService.shared.publishOwnerDMInboxMove(from: oldInbox, to: "")
        }
    }
}
#endif
