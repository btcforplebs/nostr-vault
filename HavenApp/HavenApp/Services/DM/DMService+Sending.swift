import Foundation
import Combine

extension DMService {
    func getActivePrivateKey() throws -> String {
        let config = ConfigService.shared.config
        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = activeNpub.isEmpty || activeNpub == config.ownerNpub

        if signingAsOwner {
            if !config.ownerNcryptsec.isEmpty {
                guard let password = NIP49Service.getPasswordFromKeychain() else {
                    throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Password required for encrypted key"])
                }
                return try config.getDecryptedHexKey(password: password)
            } else {
                guard let key = config.ownerHexKey, !key.isEmpty else {
                    throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sender private key not available"])
                }
                return key
            }
        } else {
            if let hexKey = try ConfigService.shared.getCredentialHexKey(forNpub: activeNpub) {
                return hexKey
            } else {
                throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No private key credential stored for active account \(activeNpub.prefix(8))"])
            }
        }
    }

    /// Whether inbound NIP-04 DMs can be decrypted for the active account.
    /// Mirrors getActivePrivateKey()'s branching but only checks that key
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

    /// Whether the owner account can sign (NIP-42 AUTH always signs as owner).
    /// Presence-only, like canDecryptNIP04(); NIP-46 defers to the bunker.
    func canSignAsOwner() -> Bool {
        let config = ConfigService.shared.config
        if config.activeSigningMode() == "nip46" { return true }
        if !config.ownerNcryptsec.isEmpty {
            return NIP49Service.getPasswordFromKeychain() != nil
        }
        return !(config.ownerHexKey ?? "").isEmpty
    }

    func sendDM(content: String, to recipientHexPubkey: String, useNIP04: Bool = false) async throws {
        if useNIP04 {
            try await sendNIP04DM(content: content, to: recipientHexPubkey)
        } else {
            try await sendNIP17DM(content: content, to: recipientHexPubkey)
        }
    }

    /// Send a NIP-17 encrypted DM (default, recommended)
    private func sendNIP17DM(content: String, to recipientHexPubkey: String) async throws {
        let ownHexPubkey = loadedAccountPubkey
        guard !ownHexPubkey.isEmpty else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active account loaded"])
        }

        // ── Step 1: Optimistic UI update (instant) ──
        let optimisticId = UUID().uuidString
        let message = DMMessage(
            id: optimisticId,
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

        // ── Step 2: Background crypto + network I/O ──
        let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
        let senderPrivkey: String? = isNIP46 ? nil : try getActivePrivateKey()
        let rumorPTags = [["p", recipientHexPubkey]]
        let generation = self.switchGeneration

        Task { [weak self] in
            guard let self = self else { return }

            do {
                // Create both gift wraps concurrently
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

                guard self.switchGeneration == generation else { return }

                // Its relay notification must not announce your own message.
                if self.sentSelfWrapIds.count > 500 { self.sentSelfWrapIds.removeAll() }
                self.sentSelfWrapIds.insert(selfGiftWrap.id)

                // Publish both to local relay (non-blocking, reuses persistent connection)
                self.publishToInbox(giftWrap)
                self.publishToInbox(selfGiftWrap)

                // Your own copy goes to your DM inbox list — the same list
                // every device reads from — never to whichever of your relay
                // lists a lookup happens to find first. Looking yours up the
                // way a recipient's is looked up could land on your general
                // (kind 10002) relays, which no device reads DMs from, so the
                // message never appeared on your other devices.
                let ownRelays = self.ownDMInboxRelays()
                for relayURL in ownRelays {
                    self.publishAuthenticated(selfGiftWrap, url: relayURL)
                }

                let rRelays = await self.fetchRecipientDMRelays(recipientHexPubkey)
                for relayURL in rRelays {
                    self.publishAuthenticated(giftWrap, url: relayURL)
                }
            } catch {
                #if DEBUG
                print("DMService: Background DM publish failed: \(error)")
                #endif
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

        // Encrypt content using NIP-04
        let encryptedContent: String
        if isNIP46 {
            encryptedContent = try await NIP04Service.encryptAsync(plaintext: content, remotePubkey: recipientHexPubkey)
        } else {
            let senderPrivkey = try getActivePrivateKey()
            encryptedContent = try NIP04Service.encrypt(plaintext: content, remotePubkey: recipientHexPubkey, localPrivkey: senderPrivkey)
        }

        // Create kind 4 event
        let tags: [[String]] = [["p", recipientHexPubkey]]
        guard let event = await NostrService.shared.signEventAsync(kind: 4, content: encryptedContent, tags: tags) else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to sign NIP-04 event"])
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
        let generation = self.switchGeneration

        Task { [weak self] in
            guard let self = self else { return }
            guard self.switchGeneration == generation else { return }

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
