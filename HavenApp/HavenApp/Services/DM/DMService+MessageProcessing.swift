import Foundation
import Combine

extension DMService {
    func processMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let type = json[0] as? String else {
                return
            }

            switch type {
            case "AUTH":
                // NIP-42: Relay sent AUTH challenge
                if let challenge = json[safe: 1] as? String {
                    #if DEBUG
                    print("🔐 Received AUTH challenge from chat relay")
                    #endif
                    DispatchQueue.main.async {
                        self.handleAuthChallenge(challenge)
                    }
                }
            case "OK":
                // Response to our AUTH event
                if let eventId = json[safe: 1] as? String,
                   let success = json[safe: 2] as? Bool {
                    DispatchQueue.main.async {
                        if success {
                            #if DEBUG
                            print("✅ AUTH successful, subscribing to DMs...")
                            #endif
                            let wasAuthenticated = self.isAuthenticated
                            self.isAuthenticated = true
                            self.pendingAuthChallenge = nil
                            if let client = self.inboxClient {
                                self.sendInboxSubscription(to: client)
                            }
                            // On first auth, also fetch from external relays for history
                            if !wasAuthenticated {
                                self.fetchFromExternalRelays()
                            }
                        } else {
                            let reason = json[safe: 3] as? String ?? "unknown"
                            #if DEBUG
                            print("❌ AUTH failed for \(eventId.prefix(8)): \(reason)")
                            #endif
                        }
                    }
                }
            case "EVENT":
                if let eventData = json[safe: 2] as? [String: Any],
                   let eventJSON = try? JSONSerialization.data(withJSONObject: eventData),
                   let event = try? JSONDecoder().decode(NostrEvent.self, from: eventJSON) {
                    DispatchQueue.main.async {
                        self.handleIncomingGiftWrap(event)
                    }
                }
            case "EOSE":
                DispatchQueue.main.async {
                    self.isLoading = false
                    #if DEBUG
                    print("📭 Finished loading stored DMs")
                    #endif
                }
            default:
                break
            }
        } catch {
            #if DEBUG
            print("❌ Failed to process DM message: \(error)")
            #endif
        }
    }

    /// Signs the /chat AUTH challenge again once the owner's signer can answer
    /// (the owner's bunker just connected in the background).
    func retryPendingAuth() {
        guard !isAuthenticated, let challenge = pendingAuthChallenge else { return }
        handleAuthChallenge(challenge, isRetry: true)
    }

    /// `isRetry`: this challenge already waited for the owner's signer once.
    /// A retry that fails does not log the owner in again, or a signer that
    /// keeps refusing would loop.
    private func handleAuthChallenge(_ challenge: String, isRetry: Bool = false) {
        guard let client = inboxClient else { return }

        // Watch-only: no owner key to sign NIP-42 AUTH. Skip the attempt (the
        // chat relay simply stays unauthenticated — nothing to read there anyway)
        // and warn once instead of logging a signing failure per AUTH challenge.
        // Asks about the owner, not the active account: the AUTH is owner-forced.
        guard ConfigService.shared.config.ownerCanSign(
            hasNcryptsecPassword: NIP49Service.getPasswordFromKeychain() != nil
        ) else {
            if !warnedAuthUnavailable {
                warnedAuthUnavailable = true
                #if DEBUG
                print("ℹ️ Watch-only: cannot sign NIP-42 AUTH (no owner key) — chat relay left unauthenticated")
                #endif
            }
            return
        }

        // The relay tag must match the relay's ServiceURL (its public-facing URL),
        // NOT the localhost connection URL. Khatru validates the relay tag against
        // "wss://" + config.RelayURL + "/chat", so we must use the same value here.
        let relayURL = ConfigService.shared.config.nostrURL + "/chat"

        // Sign a NIP-42 AUTH event (kind 22242)
        let tags: [[String]] = [
            ["relay", relayURL],
            ["challenge", challenge]
        ]

        // Kept until the relay accepts an AUTH, so it can be signed again once
        // the owner's signer is reachable (retryPendingAuth).
        pendingAuthChallenge = challenge

        Task {
            // Always sign AUTH with owner's key since the local relay is owned by the owner account
            guard let authEvent = await NostrService.shared.signEventAsync(kind: 22242, content: "", tags: tags, forceOwner: true) else {
                #if DEBUG
                print("Failed to sign NIP-42 AUTH event")
                #endif
                // After a restart with another account active, a bunker owner
                // has no signer session yet: open one, then retry this AUTH.
                if !isRetry { NIP46Service.shared.connectOwnerInBackgroundIfNeeded() }
                return
            }

            // Send ["AUTH", <signed_event>]
            let eventDict = eventToDict(authEvent)
            let msg = ["AUTH", eventDict] as [Any]
            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let str = String(data: data, encoding: .utf8) {
                #if DEBUG
                print("Sending AUTH response...")
                #endif
                client.send(text: str)
            }
        }
    }

    // MARK: - NIP-04 Processing

    func processNIP04Message(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let type = json[0] as? String else {
                return
            }

            switch type {
            case "EVENT":
                if let eventData = json[safe: 2] as? [String: Any],
                   let eventJSON = try? JSONSerialization.data(withJSONObject: eventData),
                   let event = try? JSONDecoder().decode(NostrEvent.self, from: eventJSON) {
                    DispatchQueue.main.async {
                        if event.kind == 1059 {
                            guard Self.isAuthentic(event) else { return }
                            self.handleIncomingGiftWrap(event)
                        } else {
                            self.handleIncomingNIP04(event)
                        }
                    }
                }
            default:
                break
            }
        } catch {
            #if DEBUG
            print("❌ Failed to process NIP-04 message: \(error)")
            #endif
        }
    }

    func handleIncomingNIP04(_ event: NostrEvent) {
        guard event.kind == 4 else { return }
        guard !seenGiftWrapIds.contains(event.id) else { return }
        // Checked before marking the id seen, so a forged copy carrying a real
        // event's id cannot shadow the real one.
        guard Self.isAuthentic(event) else { return }

        // Watch-only: no key to decrypt NIP-04. Skip WITHOUT marking the event
        // seen (so a later unlock/reconnect can still process it) and warn once,
        // rather than logging a "no key" failure per DM across a catch-up batch.
        guard canDecryptNIP04() else {
            if !warnedNIP04Unavailable {
                warnedNIP04Unavailable = true
                #if DEBUG
                print("ℹ️ Watch-only: NIP-04 DM decryption unavailable (no signing key) — skipping inbound DMs")
                #endif
            }
            return
        }

        seenGiftWrapIds.insert(event.id)
        trimSeenGiftWrapIdsIfNeeded()

        let generation = self.switchGeneration

        Task {
        do {
            // Verify account hasn't switched since we started processing
            guard self.switchGeneration == generation else { return }

            let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
            let ownPrivkey: String = isNIP46 ? "" : try getActivePrivateKey()

            let ownPubkey = self.loadedAccountPubkey
            let isFromMe = event.pubkey == ownPubkey

            // Determine counterparty
            let counterpartyPubkey: String
            if isFromMe {
                // I sent this — counterparty is in the "p" tag
                counterpartyPubkey = event.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] ?? ""
            } else {
                // Someone sent to me — counterparty is the event author
                counterpartyPubkey = event.pubkey
            }

            guard !counterpartyPubkey.isEmpty else { return }

            // Decrypt using NIP-04
            let plaintext: String
            if ConfigService.shared.config.activeSigningMode() == "nip46" {
                plaintext = try await NIP04Service.decryptAsync(ciphertext: event.content, remotePubkey: counterpartyPubkey)
            } else {
                plaintext = try NIP04Service.decrypt(ciphertext: event.content, remotePubkey: counterpartyPubkey, localPrivkey: ownPrivkey)
            }

            // Verify account hasn't switched during async decryption
            guard self.switchGeneration == generation else { return }

            let message = DMMessage(
                id: event.id,
                senderPubkey: event.pubkey,
                content: plaintext,
                timestamp: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                isFromMe: isFromMe,
                isNIP04: true
            )
            let unread = BlockedPeople.mayAlert(sender: event.pubkey, isFromMe: isFromMe,
                                                blocked: ConfigService.shared.activeAccountBlockedHexPubkeys)

            if let idx = conversations.firstIndex(where: { $0.id == counterpartyPubkey }) {
                guard !conversations[idx].messages.contains(where: { $0.id == event.id }) else { return }
                conversations[idx].messages.append(message)
                conversations[idx].messages.sort { $0.timestamp < $1.timestamp }
                if unread {
                    conversations[idx].unreadCount += 1
                }
            } else {
                let conversation = DMConversation(
                    id: counterpartyPubkey,
                    messages: [message],
                    unreadCount: unread ? 1 : 0
                )
                conversations.append(conversation)
            }

            sortConversations()
            dmUpdateSubject.send()
            saveConversations()
        } catch {
            #if DEBUG
            print("Failed to decrypt NIP-04 DM: \(error)")
            #endif
        }
        } // end Task
    }

    /// A relay can serve any event under any author. NIP-04 has no MAC, so a
    /// re-IV'd copy of a real DM decrypts to altered text; only the signature
    /// ties it to its author.
    static func isAuthentic(_ event: NostrEvent) -> Bool {
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else { return false }
        return NostrEventVerifier.isValid(json: json)
    }
}
