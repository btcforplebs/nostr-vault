import Foundation

/// The live `/files` subscription (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md
/// §1 "Live"): while a Media tab is open, one REQ
/// `{"kinds":[1063,5],"#p":[owner]}` stays open after EOSE, AUTHed with this
/// device's mesh key, never the account key. A drop (sleep, the mesh going
/// away) asks again from the newest note seen, less
/// `FileNotesState.resubscribeOverlap`.
///
/// Where: on iPhone/iPad the media vault (`HomeVaultSender.mediaVault`, a
/// kiosk phone or the Mac by mesh npub) over the mesh; on the Mac its own
/// relay on loopback. With no vault, or another account active, it waits and
/// the Media tab shows what it showed before. The twin of Android's
/// `FileNotesLive.kt`.
@MainActor
final class FileNotesLive: ObservableObject {
    static let shared = FileNotesLive()

    /// One tile per hash some live note names, newest first.
    @Published private(set) var tiles: [FileNoteTile] = []

    private var state = FileNotesState()
    /// Which room `state` is for: a new vault or owner starts over.
    private var room: String?
    private var watchers = 0
    private var loop: Task<Void, Never>?
    private var socket: FilesSocket?

    private static let idle: TimeInterval = 30

    /// A Media tab appeared: open the room while any is shown.
    func start() {
        watchers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        loop?.cancel()
        loop = nil
        socket?.close()
        socket = nil
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            guard let target = await Self.target() else {
                if room != nil { reset(to: nil) }
                try? await Task.sleep(nanoseconds: UInt64(Self.idle * 1_000_000_000))
                continue
            }
            // Stopped while the mesh was dialled: a newer loop may own the socket.
            guard !Task.isCancelled else { return }
            let key = target.owner + "|" + target.url.absoluteString
            if room != key { reset(to: key, owner: target.owner) }
            let socket = FilesSocket(url: target.url, vaultNpub: target.vaultNpub)
            self.socket = socket
            if await socket.auth() {
                failures = 0
                let filter = FileNote.liveFilter(owner: target.owner, since: state.since)
                await socket.subscribe(subId: "files-live", filter: filter) { [weak self] event in
                    self?.apply(event, room: key)
                }
            } else {
                print("FileNotesLive: /files did not take this device's AUTH")
            }
            socket.close()
            if self.socket === socket { self.socket = nil }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay(afterFailures: failures) * 1_000_000_000))
            failures += 1
        }
    }

    private func apply(_ event: [String: Any], room key: String) {
        guard room == key else { return }
        if state.apply(event) != .none { tiles = state.tiles }
        scheduleEmojiIngest()
    }

    private var emojiIngest: Task<Void, Never>?

    /// Hands the room's emoji notes to the Emoji page (EmojiVaultStore),
    /// once per burst: a first sync brings thousands of notes at once.
    private func scheduleEmojiIngest() {
        guard emojiIngest == nil else { return }
        emojiIngest = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.emojiIngest = nil
            guard let owner = self.state.owner else { return }
            EmojiVaultStore.shared.ingest(owner: owner, copies: self.state.emojiCopies, plain: self.state.plainHashes)
        }
    }

    private func reset(to key: String?, owner: String? = nil) {
        room = key
        state = FileNotesState(owner: owner)
        if !tiles.isEmpty { tiles = [] }
    }

    /// 5 s doubling to a minute.
    nonisolated static func retryDelay(afterFailures n: Int) -> TimeInterval {
        min(60, 5 * pow(2, Double(min(max(n, 0), 4))))
    }

    struct Target {
        let url: URL
        /// The vault's mesh npub over the mesh; nil on this machine's own relay.
        let vaultNpub: String?
        let owner: String
    }

    /// Where this device reads `/files` now, or nil.
    static func target() async -> Target? {
        let active = NostrService.shared.activeHexPubkey
        guard FileNote.isHex64(active) else { return nil }
        #if os(iOS)
        guard let vault = HomeVaultSender.shared.mediaVault, vault.ownerHex == active,
              let base = await FipsMeshService.shared.ingressURL(meshNpub: vault.meshNpub),
              let url = FileNote.filesURL(base: base) else { return nil }
        return Target(url: url, vaultNpub: vault.meshNpub, owner: active)
        #else
        let config = ConfigService.shared.config
        guard Bech32.decode(config.ownerNpub)?.hexString.lowercased() == active,
              RelayProcessManager.shared.isRunning,
              let base = URL(string: config.nostrURL), let url = FileNote.filesURL(base: base) else { return nil }
        return Target(url: url, vaultNpub: nil, owner: active)
        #endif
    }
}
