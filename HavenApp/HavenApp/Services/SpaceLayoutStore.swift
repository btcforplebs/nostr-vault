import Foundation
import Combine

/// The active account's rail pins and Your space panels (`SpaceLayout`,
/// docs/SPACE_LAYOUT.md). Drawn from the copy on this device, which every
/// edit writes at once; synced through the account's own relays as one
/// NIP-78 event, NIP-44 encrypted to self, 2 s after the last edit.
@MainActor
final class SpaceLayoutStore: ObservableObject {
    static let shared = SpaceLayoutStore()

    /// The sections the iPad rail has, in the format's default order.
    static let railSections = ["feed", "search", "profile", "wot", "vault"]
    /// Your space's panels on the iPad, in the default order. Same ids as the web's panels.js.
    static let panelIds = ["live-vault", "wot-mini", "messages", "my-devices"]

    @Published private(set) var layout: SpaceLayout = .defaultLayout(panelIds: SpaceLayoutStore.panelIds)

    private var owner = ""
    private var publishTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// A downloaded layout from a newer format: left alone, never written over.
    private var remoteIsNewerFormat = false
    /// This device has seen the account's synced layout: opened it, or every
    /// relay asked confirmed there is none. Until then edits stay on the
    /// device, so a tap before (or after a failed) read can't overwrite pins
    /// made on another device. A relay that didn't answer isn't "none".
    private var syncedBaseKnown = false
    private var pullTask: Task<Void, Never>?

    static func key(_ owner: String) -> String { "nv-space-layout:\(owner)" }

    private init() {
        // The account itself, not `$config`: that fires in willSet, while the
        // active key still names the account being left.
        ConfigService.shared.$activeAccountHexPubkey
            .map { $0.lowercased() }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hex in self?.attach(hex) }
            .store(in: &cancellables)
        // A bunker that finishes connecting can now open the synced layout.
        NIP46Service.shared.$connectionState
            .map { $0 == .connected }
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startPull() }
            .store(in: &cancellables)
    }

    // MARK: Account

    private func attach(_ hex: String) {
        guard hex != owner else { return }
        publishTask?.cancel()
        pullTask?.cancel()
        pullTask = nil
        owner = hex
        remoteIsNewerFormat = false
        syncedBaseKnown = false
        layout = Self.readLocal(hex) ?? .defaultLayout(panelIds: Self.panelIds)
        startPull()
    }

    /// Reads the account's synced layout, once at a time.
    private func startPull() {
        let account = owner
        guard !account.isEmpty, pullTask == nil, !syncedBaseKnown else { return }
        pullTask = Task { [weak self] in
            await self?.pull(for: account)
            guard let self, self.owner == account else { return }
            self.pullTask = nil
        }
    }

    private static func readLocal(_ hex: String) -> SpaceLayout? {
        guard !hex.isEmpty, let data = UserDefaults.standard.data(forKey: key(hex)) else { return nil }
        return SpaceLayout.decode(data, sections: railSections, panelIds: panelIds)
    }

    // MARK: Edits

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    /// Applies an edit: drawn at once, saved on the device, synced 2 s later.
    func edit(_ change: (SpaceLayout, Int64) -> SpaceLayout?) {
        guard let next = change(layout, now), next != layout else { return }
        layout = next
        saveLocal()
        schedulePublish()
    }

    func setPanel(_ id: String, on: Bool? = nil, open: Bool? = nil) {
        edit { $0.settingPanel(id, on: on, open: open, at: $1) }
    }

    func movePanel(_ id: String, by delta: Int) {
        edit { $0.movingPanel(id, by: delta, ids: Self.panelIds, at: $1) }
    }

    func resetPanels() { edit { $0.resettingPanels(panelIds: Self.panelIds, at: $1) } }

    /// False when it is already pinned or the rail is full.
    @discardableResult
    func addPin(_ pin: SpaceLayout.Pin) -> Bool {
        guard layout.addingPin(pin, at: now) != nil else { return false }
        edit { $0.addingPin(pin, at: $1) }
        return true
    }

    func removePin(_ id: String) { edit { $0.removingPin(id, at: $1) } }

    func movePins(from source: IndexSet, to destination: Int) {
        edit { $0.movingPins(from: source, to: destination, sections: Self.railSections, at: $1) }
    }

    func isPinned(_ kind: SpaceLayout.Pin.Kind) -> Bool {
        guard let pin = SpaceLayout.Pin.favourite(kind) else { return false }
        return layout.pins.contains { $0.id == pin.id }
    }

    private func saveLocal() {
        guard !owner.isEmpty else { return }
        UserDefaults.standard.set(layout.encoded(), forKey: Self.key(owner))
    }

    // MARK: Sync (NIP-78)

    private func schedulePublish() {
        // Not before this device has seen what is synced: ask again instead.
        // A read that finds this copy newer publishes it then.
        guard syncedBaseKnown else { startPull(); return }
        publishTask?.cancel()
        let account = owner
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.push(for: account)
        }
    }

    /// Publishes the device's copy, unless the account changed or the event
    /// on the relays is from a newer format.
    private func push(for account: String) async {
        guard account == owner, !account.isEmpty, syncedBaseKnown, !remoteIsNewerFormat else { return }
        let lock = ModePostPublisher.lockAccount(configService: ConfigService.shared)
        guard lock.hex.lowercased() == account,
              let plaintext = String(data: layout.encoded(), encoding: .utf8) else { return }
        do {
            let ciphertext = try await SpaceLayoutCrypto.encryptToSelf(plaintext, me: lock.hex)
            // Never publish anything that is not ciphertext.
            guard SpaceLayoutCrypto.isCiphertext(ciphertext, plaintext: plaintext),
                  account == owner else { return }
            try await ModePostPublisher.publish(kind: 30078, content: ciphertext, tags: SpaceLayoutCrypto.tags,
                                                nostrService: NostrService.shared, lockedTo: lock)
        } catch {
            #if DEBUG
            print("SpaceLayoutStore: not synced (\(type(of: error)))")
            #endif
        }
    }

    /// Reads the account's synced layout; the newer `at` wins. Marks the
    /// synced base known only when the event was opened, or every relay
    /// asked confirmed there is none; otherwise edits stay on the device and
    /// the next edit asks again.
    private func pull(for account: String) async {
        // A bunker still connecting can't decrypt: wait for a later ask.
        if SpaceLayoutCrypto.usesRemoteSigner, !NIP46Service.shared.isConnected { return }
        let config = ConfigService.shared.config
        let lookup = await NostrService.shared.lookupNewestReplaceable(
            kind: 30078, for: account, alsoAsk: config.readRelays, dTag: SpaceLayout.syncD)
        guard account == owner, !Task.isCancelled else { return }
        var plaintext: String?
        if let event = lookup.event {
            // Found but not opened (wrong author, empty, decrypt refused or
            // failed): not "none", so the base stays unknown.
            guard event.pubkey.lowercased() == account, !event.content.isEmpty,
                  let opened = try? await SpaceLayoutCrypto.decryptFromSelf(event.content, me: account),
                  account == owner, !Task.isCancelled else { return }
            plaintext = opened
        }
        let decision = SpaceLayout.syncRead(local: layout, plaintext: plaintext,
                                            confirmedNone: lookup.event == nil && lookup.confirmedNone,
                                            sections: Self.railSections, panelIds: Self.panelIds)
        remoteIsNewerFormat = decision.newerFormat
        syncedBaseKnown = decision.baseKnown
        if decision.layout != layout {
            layout = decision.layout
            saveLocal()
        }
        if decision.publish { schedulePublish() }
    }
}

/// NIP-44 to the account's own key, with the local key or its remote signer,
/// as the wallet backup does (`NWCBackupService`).
@MainActor
enum SpaceLayoutCrypto {
    static let tags: [[String]] = [["d", SpaceLayout.syncD], ["client", "Nostr Vault"], ["encryption", "nip44"]]

    enum CryptoError: Error { case noKey }

    static var usesRemoteSigner: Bool { ConfigService.shared.config.activeSigningMode() == "nip46" }

    static func encryptToSelf(_ plaintext: String, me: String) async throws -> String {
        if usesRemoteSigner { return try await NIP44Service.encryptAsync(plaintext: plaintext, recipientPubkey: me) }
        guard let sk = try? DMService.shared.getActivePrivateKey() else { throw CryptoError.noKey }
        return try NIP44Service.encrypt(plaintext: plaintext, recipientPubkey: me, senderPrivkey: sk)
    }

    static func decryptFromSelf(_ ciphertext: String, me: String) async throws -> String {
        if usesRemoteSigner { return try await NIP44Service.decryptAsync(ciphertext: ciphertext, senderPubkey: me) }
        guard let sk = try? DMService.shared.getActivePrivateKey() else { throw CryptoError.noKey }
        return try NIP44Service.decrypt(ciphertext: ciphertext, senderPubkey: me, recipientPrivkey: sk)
    }

    /// Ciphertext is base64 and never holds the layout's own text.
    static func isCiphertext(_ content: String, plaintext: String) -> Bool {
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !c.isEmpty && c != plaintext && !c.contains("{") && Data(base64Encoded: c) != nil
    }
}
