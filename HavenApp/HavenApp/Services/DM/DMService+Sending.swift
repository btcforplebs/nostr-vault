import Foundation
import Combine

extension DMService {
    /// The active account's private key, opened once a session and never on
    /// the main thread (SigningKeyCache): every DM sent and opened used to run
    /// the NIP-49 scrypt again, on the main actor.
    func activePrivateKey() async throws -> String {
        let source: SigningKeySource
        switch ConfigService.shared.activeKeySource() {
        case .found(let found):
            source = found
        case .passwordMissing:
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Password required for encrypted key"])
        case .noKey:
            let config = ConfigService.shared.config
            let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
            if activeNpub.isEmpty || activeNpub == config.ownerNpub {
                throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sender private key not available"])
            }
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No private key credential stored for active account \(activeNpub.prefix(8))"])
        }
        return try await SigningKeyCache.shared.hexKeyOffMain(for: source)
    }

    /// Whether inbound NIP-04 DMs can be decrypted for the active account.
    /// Mirrors activePrivateKey()'s branching but only checks that key
    /// material is *present* — it never decrypts (no scrypt), so it is cheap to
    /// call per event. NIP-46 decrypts via the bunker; local mode needs a key.
    func canDecryptNIP04() -> Bool {
        let config = ConfigService.shared.config
        if config.activeSigningMode() == "nip46" { return true }
        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = activeNpub.isEmpty || activeNpub == config.ownerNpub
        if signingAsOwner {
            if !config.ownerNcryptsec.isEmpty {
                return NIP49Service.getPasswordFromKeychain() != nil
            }
            return !(config.ownerHexKey ?? "").isEmpty
        }
        return ConfigService.shared.hasCredential(forNpub: activeNpub)
    }

    func sendDM(content: String, to recipientHexPubkey: String, useNIP04: Bool = false) async throws {
        if useNIP04 {
            try await sendNIP04DM(content: content, to: recipientHexPubkey)
        } else {
            try await sendNIP17DM(content: content, to: recipientHexPubkey)
        }
    }

    /// Send a NIP-17 encrypted DM (default, recommended)
    ///
    /// The message joins the thread only once both gift wraps are signed. It
    /// used to be added (and saved) before the key was even read, so with no
    /// usable key, or a remote signer that was offline or timed out, the
    /// bubble stayed in the thread as sent while nothing went out, and
    /// sending again added a second copy. Now any of those throws, the
    /// caller puts the text back, and nothing is left in the thread.
    private func sendNIP17DM(content: String, to recipientHexPubkey: String) async throws {
        let ownHexPubkey = loadedAccountPubkey
        guard !ownHexPubkey.isEmpty else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active account loaded"])
        }
        let generation = self.switchGeneration

        // ── Step 1: key and both gift wraps (throws on any signer failure) ──
        let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
        let senderPrivkey: String? = isNIP46 ? nil : try await activePrivateKey()
        let rumorPTags = [["p", recipientHexPubkey]]
        async let recipientWrap = NIP17Service.createGiftWrapAsync(
            content: content,
            rumorPTags: rumorPTags,
            giftWrapRecipient: recipientHexPubkey,
            senderHexPrivkey: senderPrivkey,
            senderHexPubkey: ownHexPubkey
        )
        async let selfWrap = NIP17Service.createGiftWrapAsync(
            content: content,
            rumorPTags: rumorPTags,
            giftWrapRecipient: ownHexPubkey,
            senderHexPrivkey: senderPrivkey,
            senderHexPubkey: ownHexPubkey
        )
        let (giftWrap, selfGiftWrap) = try await (recipientWrap, selfWrap)

        // Signing can take seconds with a remote signer: an account switched
        // to meanwhile must not get this message in its threads.
        guard self.switchGeneration == generation else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "The account changed before the message was sent"])
        }

        // ── Step 2: show it ──
        let message = DMMessage(
            id: UUID().uuidString,
            senderPubkey: ownHexPubkey,
            content: content,
            timestamp: Date(),
            isFromMe: true
        )
        if let idx = conversations.firstIndex(where: { $0.id == recipientHexPubkey }) {
            conversations[idx].messages.append(message)
        } else {
            let conversation = DMConversation(
                id: recipientHexPubkey,
                messages: [message],
                unreadCount: 0
            )
            conversations.append(conversation)
        }
        sortConversations()
        saveConversations()

        // Its relay notification must not announce your own message.
        if sentSelfWrapIds.count > 500 { sentSelfWrapIds.removeAll() }
        sentSelfWrapIds.insert(selfGiftWrap.id)

        // Publish both to local relay (non-blocking, reuses persistent connection)
        publishToInbox(giftWrap)
        publishToInbox(selfGiftWrap)

        // Your own copy goes to your DM inbox list — the same list
        // every device reads from — never to whichever of your relay
        // lists a lookup happens to find first. Looking yours up the
        // way a recipient's is looked up could land on your general
        // (kind 10002) relays, which no device reads DMs from, so the
        // message never appeared on your other devices.
        for relayURL in ownDMInboxRelays() {
            publishAuthenticated(selfGiftWrap, url: relayURL)
        }

        // ── Step 3: recipient's relays (lookup in the background) ──
        Task { [weak self] in
            guard let self = self else { return }
            // Already signed by the account that wrote it and shown as sent:
            // it goes out even if the account changes during the lookup.
            let rRelays = await self.fetchRecipientDMRelays(recipientHexPubkey)
            for relayURL in rRelays {
                self.publishAuthenticated(giftWrap, url: relayURL)
            }
        }
    }

    /// Send a NIP-04 legacy DM (for compatibility with older clients)
    private func sendNIP04DM(content: String, to recipientHexPubkey: String) async throws {
        let ownHexPubkey = loadedAccountPubkey
        guard !ownHexPubkey.isEmpty else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active account loaded"])
        }
        let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
        let generation = self.switchGeneration

        // Encrypt content using NIP-04
        let encryptedContent: String
        if isNIP46 {
            encryptedContent = try await NIP04Service.encryptAsync(plaintext: content, remotePubkey: recipientHexPubkey)
        } else {
            let senderPrivkey = try await activePrivateKey()
            encryptedContent = try NIP04Service.encrypt(plaintext: content, remotePubkey: recipientHexPubkey, localPrivkey: senderPrivkey)
        }

        // Create kind 4 event
        let tags: [[String]] = [["p", recipientHexPubkey]]
        guard let event = await NostrService.shared.signEventAsync(kind: 4, content: encryptedContent, tags: tags) else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to sign NIP-04 event"])
        }
        guard self.switchGeneration == generation, event.pubkey.lowercased() == ownHexPubkey.lowercased() else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "The account changed before the message was sent"])
        }

        // ── Optimistic UI update (uses real event ID since crypto is already done) ──
        let message = DMMessage(
            id: event.id,
            senderPubkey: ownHexPubkey,
            content: content,
            timestamp: Date(),
            isFromMe: true,
            isNIP04: true
        )

        if let idx = conversations.firstIndex(where: { $0.id == recipientHexPubkey }) {
            conversations[idx].messages.append(message)
        } else {
            let conversation = DMConversation(
                id: recipientHexPubkey,
                messages: [message],
                unreadCount: 0
            )
            conversations.append(conversation)
        }
        sortConversations()
        saveConversations()

        // ── Background network I/O ──
        // No account check here: the event is signed by the account that
        // wrote it and already shown as sent, so it must go out.
        Task { [weak self] in
            guard let self = self else { return }

            // Publish to local inbox relay
            if let inboxURL = self.inboxRelayURL()?.absoluteString {
                self.fireAndForgetPublish(event, url: inboxURL)
            }

            // Fetch relay lists concurrently, then fire-and-forget to external relays
            async let recipientRelays = self.fetchRecipientDMRelays(recipientHexPubkey)
            async let ownRelays = self.fetchRecipientDMRelays(ownHexPubkey)

            let rRelays = await recipientRelays
            let oRelays = await ownRelays

            for relayURL in rRelays {
                self.fireAndForgetPublish(event, url: relayURL)
            }
            for relayURL in oRelays where !rRelays.contains(relayURL) {
                self.fireAndForgetPublish(event, url: relayURL)
            }
        }
    }
}
