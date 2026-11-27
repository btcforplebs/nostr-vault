import Foundation

/// The app's `CashuVaultIO` for one account: this device's Vault `/private`
/// relay (VaultSocket, logged in as the owner), NIP-44 to self and signing
/// with the account's own signer (local key or bunker). Every call first
/// checks that `accountHex` is still the active account and refuses
/// otherwise: only the active account's key is at hand, and a wallet event
/// must never be sealed or signed by another account.
@MainActor
enum CashuVaultLink {
    static func io(accountHex: String) -> CashuVaultIO {
        let me = accountHex.lowercased()
        return CashuVaultIO(
            query: { filter in await query(filter, as: me) },
            publish: { event in await publish(event, as: me) },
            encryptToSelf: { text in try await MuteListStore.encryptToSelf(text, me: me, nip04: false) },
            decryptFromSelf: { text in try await MuteListStore.decryptToSelf(text, me: me, nip04: false) },
            sign: { kind, createdAt, tags, content in await sign(kind, createdAt, tags, content, as: me) })
    }

    static func isActive(_ me: String) -> Bool {
        ZapPayer.activeAccountHex() == me
    }

    private static func query(_ filter: CashuVaultFilter, as me: String) async -> [CashuSignedEvent]? {
        guard isActive(me) else { return nil }
        guard let events = await VaultSocket.queryAll(path: "/private", filter: filter.json, timeout: 8) else { return nil }
        return events.compactMap(convert)
    }

    private static func publish(_ event: CashuSignedEvent, as me: String) async -> Bool {
        guard isActive(me), event.pubkey.lowercased() == me,
              let data = try? JSONEncoder().encode(event),
              let nostr = try? JSONDecoder().decode(NostrEvent.self, from: data) else { return false }
        return await VaultSocket.publish(nostr, path: "/private", timeout: 8)
    }

    private static func sign(_ kind: Int, _ createdAt: Int64, _ tags: [[String]], _ content: String,
                             as me: String) async -> CashuSignedEvent? {
        guard isActive(me) else { return nil }
        guard let event = await NostrService.shared.signEventAsync(kind: kind, content: content, tags: tags,
                                                                     notBefore: createdAt),
              event.pubkey.lowercased() == me, isActive(me) else { return nil }
        return convert(event)
    }

    private static func convert(_ event: NostrEvent) -> CashuSignedEvent? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        return try? JSONDecoder().decode(CashuSignedEvent.self, from: data)
    }
}
