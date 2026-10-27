import Foundation
import Combine

/// The signed-in accounts' mute lists beyond their public `p` tags
/// (`MuteList`): private people, and muted words, hashtags and threads.
///
/// The newest kind 10000 per account is kept as it arrived, its private part
/// still encrypted, so the list holds across launches and offline. It is
/// opened for the active account only, since that is the key (local or
/// remote signer) this device can decrypt with. It is fetched from the
/// account's relays when the app starts and on every account switch, and
/// replaced when a newer one arrives on any subscription.
final class MuteListStore {
    static let shared = MuteListStore()

    private let lock = NSLock()
    /// Opened lists, by account hex pubkey.
    private var lists: [String: MuteList] = [:]
    /// Newest kind 10000 per account hex pubkey, content still encrypted.
    private var events: [String: NostrEvent] = [:]
    /// The active account's hex pubkey, set on the main actor by `refresh()`.
    private var activeHex = ""
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private static let defaultsKey = "muteListEvents"
    /// A list dated this far ahead is not taken: it would outrank every real one.
    private static let maxSkew: Int64 = 600
    /// Asked besides the account's own relays: where lists usually are.
    static let extraRelays = ["wss://purplepag.es", "wss://relay.damus.io", "wss://relay.primal.net"]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: NostrEvent].self, from: data) {
            events = stored
        }
    }

    // MARK: - Reading

    func list(forHex hex: String) -> MuteList {
        lock.lock(); defer { lock.unlock() }
        return lists[hex.lowercased()] ?? .empty
    }

    /// The newest kind 10000 this device holds for `hex`, as it arrived.
    func storedEvent(forHex hex: String) -> NostrEvent? {
        lock.lock(); defer { lock.unlock() }
        return events[hex.lowercased()]
    }

    /// The active account's list, what the screens hide notes with.
    var active: MuteList {
        lock.lock(); defer { lock.unlock() }
        return lists[activeHex] ?? .empty
    }

    /// Private blocks for one account, added to its public ones by
    /// `ConfigService.blockedHexPubkeys(forAccount:)`.
    func privatePubkeys(forAccount npub: String) -> Set<String> {
        guard let hex = Bech32.decode(npub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString else { return [] }
        return list(forHex: hex).privatePubkeys
    }

    @MainActor
    private static var currentActiveHex: String {
        let config = ConfigService.shared.config
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let npub = active.isEmpty ? config.ownerNpub : active
        return Bech32.decode(npub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString.lowercased() ?? ""
    }

    // MARK: - Loading

    /// Opens the stored list and fetches the newest one, now and after every
    /// account switch or sign-in. Safe to call more than once.
    @MainActor
    func start() {
        guard !started else { return }
        started = true
        ConfigService.shared.activeAccountSwitches
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)
        ConfigService.shared.$config
            .map(\.ownerNpub)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    /// The active account's stored list opened, then the network's newest.
    @MainActor
    func refresh() {
        let hex = Self.currentActiveHex
        lock.lock(); activeHex = hex; lock.unlock()
        guard !hex.isEmpty else { return }
        Task {
            await open(hex: hex)
            let config = ConfigService.shared.config
            let lookup = await NostrService.shared.lookupNewestReplaceable(
                kind: 10000, for: hex, alsoAsk: Array(Set(config.readRelays + Self.extraRelays)))
            if let event = lookup.event { NostrService.shared.applyOwnMuteList(event) }
        }
    }

    /// A kind 10000 by one of this device's accounts (the caller checks), from any relay. Kept
    /// when newer than the stored one; opened when it is the active account's.
    func ingest(_ event: NostrEvent) {
        guard event.kind == 10000 else { return }
        let hex = event.pubkey.lowercased()
        let now = Int64(Date().timeIntervalSince1970)
        lock.lock()
        let current = events[hex]
        let newer = event.created_at < now + Self.maxSkew
            && (current == nil || event.created_at > current!.created_at
                || (event.created_at == current!.created_at && event.id != current!.id && event.id < current!.id))
        if newer {
            events[hex] = event
            if let data = try? JSONEncoder().encode(events) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
        }
        let retry = !newer && current?.id == event.id && !(lists[hex]?.privateNote.isEmpty ?? true)
        let isActive = hex == activeHex
        lock.unlock()
        guard newer || retry, isActive else { return }
        Task { await open(hex: hex) }
    }

    /// Opens the stored list for `hex` (the active account) and tells the
    /// screens when what it hides changed.
    private func open(hex: String) async {
        lock.lock()
        let event = events[hex]
        lock.unlock()
        guard let event else { return }
        let opened = await MuteList.read(
            tags: event.tags, content: event.content,
            decrypt44: { try await Self.decryptToSelf($0, me: hex, nip04: false) },
            decrypt04: { try await Self.decryptToSelf($0, me: hex, nip04: true) })
        lock.lock()
        guard events[hex]?.id == event.id else { lock.unlock(); return } // a newer one came in meanwhile
        let changed = lists[hex] != opened
        lists[hex] = opened
        lock.unlock()
        #if DEBUG
        print("MuteListStore: \(hex.prefix(8)) private people \(opened.privatePubkeys.count), words \(opened.words.count), hashtags \(opened.hashtags.count), threads \(opened.threads.count) \(opened.privateNote)")
        #endif
        guard changed else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
        }
    }

    /// The private part, encrypted by the user to their own key: through the
    /// remote signer when the account has one, else with the local key. Only
    /// the active account's key is at hand, so `me` must be that account.
    static func decryptToSelf(_ ciphertext: String, me: String, nip04: Bool) async throws -> String {
        try await requireActive(me)
        if await MainActor.run(body: { ConfigService.shared.config.activeSigningMode() == "nip46" }) {
            return nip04
                ? try await NIP04Service.decryptAsync(ciphertext: ciphertext, remotePubkey: me)
                : try await NIP44Service.decryptAsync(ciphertext: ciphertext, senderPubkey: me)
        }
        let sk = try await MainActor.run { try DMService.shared.getActivePrivateKey() }
        return nip04
            ? try NIP04Service.decrypt(ciphertext: ciphertext, remotePubkey: me, localPrivkey: sk)
            : try NIP44Service.decrypt(ciphertext: ciphertext, senderPubkey: me, recipientPrivkey: sk)
    }

    /// The private part encrypted to the user's own key again, the way
    /// `decryptToSelf` opens it.
    static func encryptToSelf(_ plaintext: String, me: String, nip04: Bool) async throws -> String {
        try await requireActive(me)
        if await MainActor.run(body: { ConfigService.shared.config.activeSigningMode() == "nip46" }) {
            return nip04
                ? try await NIP04Service.encryptAsync(plaintext: plaintext, remotePubkey: me)
                : try await NIP44Service.encryptAsync(plaintext: plaintext, recipientPubkey: me)
        }
        let sk = try await MainActor.run { try DMService.shared.getActivePrivateKey() }
        return nip04
            ? try NIP04Service.encrypt(plaintext: plaintext, remotePubkey: me, localPrivkey: sk)
            : try NIP44Service.encrypt(plaintext: plaintext, recipientPubkey: me, senderPrivkey: sk)
    }

    private static func requireActive(_ hex: String) async throws {
        let active = await MainActor.run { currentActiveHex }
        guard !active.isEmpty, active == hex.lowercased() else { throw NIP44Service.NIP44Error.invalidKeyFormat }
    }
}

extension MuteList {
    /// Whether a feed row is hidden by a muted word, hashtag or thread. A
    /// repost is checked by the post it shows.
    func hides(_ note: FeedNote) -> Bool {
        guard hidesNotes else { return false }
        if hides(id: note.id, content: note.content, tags: note.tags, parentId: note.parentEventId) { return true }
        if let original = note.repostedEventId, threads.contains(original.lowercased()) { return true }
        return false
    }
}
