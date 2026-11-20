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
        // Checked on the plaintext, before either encryption (SecretKeyLeak).
        guard !SecretKeyLeak.containsSecretKey(content) else { throw SecretKeyLeak.Blocked() }
        if useNIP04 {
            try await sendNIP04DM(content: content, to: recipientHexPubkey)
        } else {
            try await sendNIP17DM(content: content, to: recipientHexPubkey)
        }
    }

    /// A locked photo (DMFile) as a NIP-17 kind 15 file message: `url` names the ciphertext, the key and nonce go
    /// in the sealed rumor's tags, and this device keeps it as its `#nv-dm=` link. `after` (the words sent just
    /// before it, as their own kind 14) puts it one second later so it sorts below them, as the web does.
    func sendDMFile(url: URL, encrypted: DMFile.Encrypted, mime: String, to recipientHexPubkey: String, after: Bool = false) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let shown = DMFile.link(DMFile.Sealed(url: url, key: encrypted.key, nonce: encrypted.nonce, x: encrypted.x,
                                              ox: encrypted.ox, mime: mime))
        try await sendNIP17DM(content: url.absoluteString, to: recipientHexPubkey, rumorKind: 15,
                              fileTags: DMFile.tags(encrypted, mime: mime), shown: shown,
                              rumorTimestamp: after ? now + 1 : now)
    }

    /// Send a NIP-17 encrypted DM (default, recommended)
    ///
    /// The message joins the thread only once both gift wraps are signed. It
    /// used to be added (and saved) before the key was even read, so with no
    /// usable key, or a remote signer that was offline or timed out, the
    /// bubble stayed in the thread as sent while nothing went out, and
    /// sending again added a second copy. Now any of those throws, the
    /// caller puts the text back, and nothing is left in the thread.
    private func sendNIP17DM(content: String, to recipientHexPubkey: String, rumorKind: Int = 14,
                             fileTags: [[String]] = [], shown: String? = nil, rumorTimestamp: Int64? = nil) async throws {
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
            senderHexPubkey: ownHexPubkey,
            rumorKind: rumorKind,
            fileTags: fileTags,
            rumorTimestamp: rumorTimestamp
        )
        async let selfWrap = NIP17Service.createGiftWrapAsync(
            content: content,
            rumorPTags: rumorPTags,
            giftWrapRecipient: ownHexPubkey,
            senderHexPrivkey: senderPrivkey,
            senderHexPubkey: ownHexPubkey,
            rumorKind: rumorKind,
            fileTags: fileTags,
            rumorTimestamp: rumorTimestamp
        )
        let (giftWrap, selfGiftWrap) = try await (recipientWrap, selfWrap)

        // Signing can take seconds with a remote signer: an account switched
        // to meanwhile must not get this message in its threads.
        guard self.switchGeneration == generation else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "The account changed before the message was sent"])
        }

        // ── Step 2: show it, as sending ── (a file message as its locked link, the same text its self-copy unwraps to)
        let message = DMMessage(
            id: UUID().uuidString,
            senderPubkey: ownHexPubkey,
            content: shown ?? content,
            timestamp: Date(),
            isFromMe: true,
            sendState: .sending
        )
        addSentMessage(message, to: recipientHexPubkey)
        // Try again signs it afresh: the same text, kind and file tags.
        resends[message.id] = { [weak self] in
            try await self?.sendNIP17DM(content: content, to: recipientHexPubkey, rumorKind: rumorKind,
                                        fileTags: fileTags, shown: shown)
        }

        // Its relay notification must not announce your own message.
        if sentSelfWrapIds.count > 500 { sentSelfWrapIds.removeAll() }
        sentSelfWrapIds.insert(selfGiftWrap.id)

        // Captured now, while the account that wrote it is the loaded one: the
        // lookup and the first OK can take 20 s, and an account switched to
        // meanwhile must never get this copy or prove itself for it.
        let ownRelays = ownDMInboxRelays()

        // ── Step 3: their relays first (lookup in the background) ──
        // Your own copy goes out only once one of theirs took the message, so
        // a refused message never comes back from your own relay looking sent
        // (web: dms.js). It goes to your DM inbox list, the one every device
        // reads, never to your general (kind 10002) relays.
        Task { [weak self] in
            guard let self = self else { return }
            // Already signed by the account that wrote it: it goes out even if
            // the account changes during the lookup.
            let rRelays = await self.fetchRecipientDMRelays(recipientHexPubkey)
            let answer = self.beginDelivery(messageId: message.id, conversation: recipientHexPubkey,
                                            account: ownHexPubkey, relayCount: rRelays.count) { [weak self] in
                guard let self else { return }
                // The device's inbox connection belongs to whichever account is loaded.
                if self.switchGeneration == generation {
                    self.publishToInbox(giftWrap)
                    self.publishToInbox(selfGiftWrap)
                }
                for relayURL in ownRelays {
                    self.publishAuthenticated(selfGiftWrap, url: relayURL, sender: ownHexPubkey)
                }
            }
            for relayURL in rRelays {
                self.publishAuthenticated(giftWrap, url: relayURL, sender: ownHexPubkey) { accepted, _ in answer(accepted) }
            }
        }
    }

    /// Puts a message you just wrote into its thread (making the thread if
    /// it is the first one) and saves.
    private func addSentMessage(_ message: DMMessage, to recipientHexPubkey: String) {
        if let idx = conversations.firstIndex(where: { $0.id == recipientHexPubkey }) {
            conversations[idx].messages.append(message)
        } else {
            conversations.append(DMConversation(id: recipientHexPubkey, messages: [message], unreadCount: 0))
        }
        sortConversations()
        saveConversations()
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

        // ── Show it, as sending (the real event id: the crypto is done) ──
        let message = DMMessage(
            id: event.id,
            senderPubkey: ownHexPubkey,
            content: content,
            timestamp: Date(),
            isFromMe: true,
            isNIP04: true,
            sendState: .sending
        )
        addSentMessage(message, to: recipientHexPubkey)
        resends[message.id] = { [weak self] in
            try await self?.sendNIP04DM(content: content, to: recipientHexPubkey)
        }

        // The local inbox as it is now, for the account that wrote it.
        let inboxURL = inboxRelayURL()?.absoluteString

        // ── Their relays first; your inbox and your own relays once one took it ──
        // No account check here: the event is signed by the account that
        // wrote it, so it must go out.
        Task { [weak self] in
            guard let self = self else { return }
            async let recipientRelays = self.fetchRecipientDMRelays(recipientHexPubkey)
            async let ownRelays = self.fetchRecipientDMRelays(ownHexPubkey)
            let rRelays = await recipientRelays
            let oRelays = await ownRelays

            let answer = self.beginDelivery(messageId: message.id, conversation: recipientHexPubkey,
                                            account: ownHexPubkey, relayCount: rRelays.count) { [weak self] in
                guard let self else { return }
                if self.switchGeneration == generation, let inboxURL {
                    self.fireAndForgetPublish(event, url: inboxURL)
                }
                for relayURL in oRelays where !rRelays.contains(relayURL) {
                    self.fireAndForgetPublish(event, url: relayURL)
                }
            }
            for relayURL in rRelays {
                self.fireAndForgetPublish(event, url: relayURL) { accepted in answer(accepted) }
            }
        }
    }
}
