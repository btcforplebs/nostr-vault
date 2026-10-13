import Foundation
import Combine
import SwiftUI

extension NostrService {
    // MARK: - Publishing

    /// Signs an event using the stored nsec via the Go backend
    /// - Parameters:
    ///   - kind: The event kind
    ///   - content: The event content
    ///   - tags: The event tags
    ///   - password: Optional password for NIP-49 encrypted keys. If not provided, will attempt to retrieve from Keychain.
    /// - Returns: The signed NostrEvent, or nil if signing fails
    /// - Parameter signAsNpub: Sign as this specific account instead of whichever is
    ///   currently active, WITHOUT touching config.activeAccountNpub. Use this for any
    ///   publish that targets a non-active account (e.g. syncing a secondary account's
    ///   mute/relay list) — temporarily mutating the shared active-account pointer is
    ///   observed by every subscriber (FeedService/NostrService's own account-switch
    ///   handlers), making a background publish look like a real user-driven switch.
    func signEvent(kind: Int, content: String, tags: [[String]] = [], password: String? = nil, forceOwner: Bool = false, signAsNpub: String? = nil) -> NostrEvent? {
        var sk: String?
        let config = ConfigService.shared.config

        // Determine which account is signing
        let activeNpub = (signAsNpub ?? config.activeAccountNpub).trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = forceOwner || activeNpub.isEmpty || activeNpub == config.ownerNpub
        
        if signingAsOwner {
            // ── Owner signing path (existing logic) ──────────────────────────
            if !config.ownerNcryptsec.isEmpty {
                let pwd = password ?? NIP49Service.getPasswordFromKeychain()
                if let pwd = pwd {
                    do {
                        sk = try config.getDecryptedHexKey(password: pwd)
                    } catch {
                        #if DEBUG
                        print("NostrService: NIP-49 decrypt failed: \(error.localizedDescription)")
                        #endif
                        return nil
                    }
                } else {
                    #if DEBUG
                    print("NostrService: NIP-49 key exists but no password in Keychain")
                    #endif
                    return nil
                }
            } else {
                sk = config.ownerHexKey
            }
        } else {
            // ── Whitelisted account signing path ─────────────────────────────
            do {
                if let hexKey = try ConfigService.shared.getCredentialHexKey(forNpub: activeNpub) {
                    sk = hexKey
                } else {
                    // No credential stored — do NOT fall back to owner key, as that
                    // would silently post from the wrong account.
                    #if DEBUG
                    print("NostrService: No credential for active account \(activeNpub.prefix(16))..., cannot sign")
                    #endif
                    return nil
                }
            } catch {
                #if DEBUG
                print("NostrService: Failed to decrypt whitelisted account key: \(error.localizedDescription)")
                #endif
                return nil
            }
        }

        guard let sk = sk, !sk.isEmpty else {
            #if DEBUG
            print("NostrService: Cannot sign - no private key available")
            #endif
            return nil
        }

        // Use the signing account's pubkey for the event — decoded directly from
        // activeNpub (which already reflects signAsNpub when provided) rather than
        // the cached activeHexPubkey, which only ever reflects the real active account.
        let signingPubkey = signingAsOwner ? ownerHexPubkey : (Bech32.decode(activeNpub)?.hexString ?? activeHexPubkey)

        let finalTags = EventPublisher.appendClientTag(to: tags, kind: kind)
        let eventDict = EventPublisher.buildUnsignedEvent(pubkey: signingPubkey, kind: kind, content: content, tags: finalTags)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            #if DEBUG
            print("NostrService: Failed to serialize event to JSON")
            #endif
            return nil
        }

        return EventPublisher.signWithGoBackend(eventJSON: jsonStr, secretKey: sk)
    }

    /// Async variant of signEvent that supports both local key and NIP-46 remote signing.
    /// When signingMode is "nip46", delegates to NIP46Service. Otherwise wraps the local signEvent().
    /// - Parameter signAsNpub: See signEvent(_:signAsNpub:) — signs as this account
    ///   without touching config.activeAccountNpub. A non-active account that signs
    ///   with a bunker is refused (returns nil): the bunker connection belongs to the
    ///   active account, and a background publish can't switch it.
    func signEventAsync(kind: Int, content: String, tags: [[String]] = [], password: String? = nil, forceOwner: Bool = false, signAsNpub: String? = nil) async -> NostrEvent? {
        let config = ConfigService.shared.config
        let mode = config.activeSigningMode()

        // Signing as a non-active account: its own signing mode decides. A bunker
        // connection belongs to the active account only, so a non-active bunker
        // account cannot be signed for here — refuse rather than let the active
        // account's bunker sign (and publish) an event meant for another identity.
        let activeNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        if let target = signAsNpub?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty, target != activeNpub {
            let targetUsesBunker = config.accountSigningModes[target] != "local"
                && ConfigService.shared.hasBunkerConfig(forNpub: target)
            if targetUsesBunker {
                #if DEBUG
                print("NostrService: signEventAsync refused — \(target.prefix(20)) signs with a bunker and is not the active account")
                #endif
                return nil
            }
            return signEvent(kind: kind, content: content, tags: tags, password: password, forceOwner: forceOwner, signAsNpub: target)
        }

        #if DEBUG
        print("NostrService: signEventAsync mode=\(mode) activeNpub=\(config.activeAccountNpub.prefix(20)) ownerNpub=\(config.ownerNpub.prefix(20)) forceOwner=\(forceOwner)")
        #endif

        // Owner-only events (the local relay's AUTH) while another account is
        // active: they used to go to the ACTIVE account's bunker, which cannot
        // sign for the owner's key, so every reconnect sent a doomed request
        // to that signer. Route them to the owner's own signer instead.
        if forceOwner, !ownerHexPubkey.isEmpty, ownerHexPubkey != activeHexPubkey {
            let ownerNpub = config.ownerNpub
            // The owner's own signing mode, explicit or found from its bunker
            // config: a wizard-made bunker has no accountSigningModes entry.
            guard config.ownerSignsWithBunker, let ownerSigner = config.accountBunkerConfigs[ownerNpub]?.signerPubkey, !ownerSigner.isEmpty else {
                return signEvent(kind: kind, content: content, tags: tags, password: password, forceOwner: true)
            }
            let finalTags = EventPublisher.appendClientTag(to: tags, kind: kind)
            let eventDict = EventPublisher.buildUnsignedEvent(pubkey: ownerHexPubkey, kind: kind, content: content, tags: finalTags)
            guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }
            do {
                // Only through a session that is already live; never a new
                // login just for this.
                let signedJSON = try await NIP46Service.shared.signEvent(eventJSON: jsonStr, withSigner: ownerSigner)
                guard let data = signedJSON.data(using: .utf8) else { return nil }
                return try JSONDecoder().decode(NostrEvent.self, from: data)
            } catch {
                #if DEBUG
                print("NostrService: owner-signed kind \(kind) skipped — no live session for the owner's signer: \(error)")
                #endif
                return nil
            }
        }

        if mode == "nip46" {
            // Determine the signing pubkey from the active account (or owner if forced)
            let signingPubkey = forceOwner ? ownerHexPubkey : activeHexPubkey

            guard !signingPubkey.isEmpty else {
                #if DEBUG
                print("NostrService: NIP-46 sign failed - no pubkey available")
                #endif
                return nil
            }

            let finalTags = EventPublisher.appendClientTag(to: tags, kind: kind)
            let eventDict = EventPublisher.buildUnsignedEvent(pubkey: signingPubkey, kind: kind, content: content, tags: finalTags)

            guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                #if DEBUG
                print("NostrService: NIP-46 sign failed - JSON serialization error")
                #endif
                return nil
            }

            do {
                #if DEBUG
                print("NostrService: NIP-46 signing kind \(kind) event (tags=\(finalTags.map { $0.first ?? "?" })), sending to bunker…")
                print("NostrService: NIP-46 outgoing event JSON: \(jsonStr.prefix(500))")
                #endif
                let signedJSON = try await NIP46Service.shared.signEvent(eventJSON: jsonStr)
                #if DEBUG
                print("NostrService: NIP-46 bunker returned \(signedJSON.prefix(300))")
                #endif
                guard let signedData = signedJSON.data(using: .utf8) else {
                    #if DEBUG
                    print("NostrService: NIP-46 sign failed - response not valid UTF-8")
                    #endif
                    return nil
                }
                let event = try JSONDecoder().decode(NostrEvent.self, from: signedData)
                #if DEBUG
                print("NostrService: NIP-46 signed event id=\(event.id.prefix(8)) pubkey=\(event.pubkey.prefix(8)) sig=\(event.sig.prefix(8))")
                #endif
                return event
            } catch {
                #if DEBUG
                print("NostrService: NIP-46 sign FAILED for kind \(kind): \(error)")
                #endif
                if kind == 24242 {
                    #if DEBUG
                    print("NostrService: Blossom auth (kind 24242) signing failed — remote signer may not support this event kind or may require manual approval")
                    #endif
                }
                return nil
            }
        } else {
            return signEvent(kind: kind, content: content, tags: tags, password: password, forceOwner: forceOwner, signAsNpub: signAsNpub)
        }
    }

    // MARK: - Proof of Work Mining + Signing

    /// Resolves the secret key and builds the unsigned-event JSON for local signing.
    /// Runs on the main actor (touches config/Keychain); returns Sendable primitives so
    /// the heavy mine+sign can be handed to a background executor without crossing actors.
    private func prepareLocalSigning(kind: Int, content: String, tags: [[String]], password: String?, forceOwner: Bool) -> (jsonStr: String, secretKey: String)? {
        var sk: String?
        let config = ConfigService.shared.config

        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = forceOwner || activeNpub.isEmpty || activeNpub == config.ownerNpub

        if signingAsOwner {
            if !config.ownerNcryptsec.isEmpty {
                let pwd = password ?? NIP49Service.getPasswordFromKeychain()
                if let pwd = pwd {
                    do {
                        sk = try config.getDecryptedHexKey(password: pwd)
                    } catch {
                        #if DEBUG
                        print("NostrService: NIP-49 decrypt failed: \(error.localizedDescription)")
                        #endif
                        return nil
                    }
                } else {
                    #if DEBUG
                    print("NostrService: NIP-49 key exists but no password in Keychain")
                    #endif
                    return nil
                }
            } else {
                sk = config.ownerHexKey
            }
        } else {
            do {
                if let hexKey = try ConfigService.shared.getCredentialHexKey(forNpub: activeNpub) {
                    sk = hexKey
                } else {
                    #if DEBUG
                    print("NostrService: No credential for active account \(activeNpub.prefix(16))..., cannot sign")
                    #endif
                    return nil
                }
            } catch {
                #if DEBUG
                print("NostrService: Failed to decrypt whitelisted account key: \(error.localizedDescription)")
                #endif
                return nil
            }
        }

        guard let sk = sk, !sk.isEmpty else {
            #if DEBUG
            print("NostrService: Cannot sign - no private key available")
            #endif
            return nil
        }

        let signingPubkey = signingAsOwner ? ownerHexPubkey : activeHexPubkey
        let finalTags = EventPublisher.appendClientTag(to: tags, kind: kind)
        let eventDict = EventPublisher.buildUnsignedEvent(pubkey: signingPubkey, kind: kind, content: content, tags: finalTags)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            #if DEBUG
            print("NostrService: Failed to serialize event to JSON")
            #endif
            return nil
        }

        return (jsonStr, sk)
    }

    /// Signs an event with NIP-13 Proof of Work mining via the Go backend.
    /// When difficulty > 0, mines a nonce tag before signing. Falls back to plain signing on failure.
    ///
    /// NOTE: PoW mining is a tight CPU loop (up to `maxAttempts` SHA256 hashes). This synchronous
    /// entry point runs it on the calling thread — for the main actor, prefer `mineAndSignEventAsync`,
    /// which offloads the mine to a background executor so the UI/run loop stays responsive.
    func mineAndSignEvent(kind: Int, content: String, tags: [[String]] = [], difficulty: Int = 0, maxAttempts: Int = 10_000_000, password: String? = nil, forceOwner: Bool = false) -> NostrEvent? {
        guard let prep = prepareLocalSigning(kind: kind, content: content, tags: tags, password: password, forceOwner: forceOwner) else {
            return nil
        }
        return EventPublisher.mineAndSignWithGoBackend(eventJSON: prep.jsonStr, secretKey: prep.secretKey, difficulty: difficulty, maxAttempts: maxAttempts)
    }

    /// Async variant of mineAndSignEvent that supports NIP-46 remote signing.
    /// For NIP-46 mode: skips PoW (no secret key available) and delegates to signEventAsync.
    /// For local mode: mines PoW and signs via the Go backend on a background executor so the
    /// main thread is never blocked by the mining loop (which would otherwise trip the iOS watchdog).
    func mineAndSignEventAsync(kind: Int, content: String, tags: [[String]] = [], difficulty: Int = 0, maxAttempts: Int = 10_000_000, password: String? = nil) async -> NostrEvent? {
        let config = ConfigService.shared.config
        let mode = config.activeSigningMode()

        if mode == "nip46" {
            // NIP-46: we don't have the secret key, so skip PoW
            return await signEventAsync(kind: kind, content: content, tags: tags, password: password)
        }

        // Resolve key + build JSON on the main actor (Keychain/config access)…
        guard let prep = prepareLocalSigning(kind: kind, content: content, tags: tags, password: password, forceOwner: false) else {
            return nil
        }
        // …then mine + sign off the main thread. `mineAndSignWithGoBackend` is a non-isolated
        // static func operating only on the Sendable Strings we pass in.
        let jsonStr = prep.jsonStr
        let secretKey = prep.secretKey
        return await Task.detached(priority: .userInitiated) {
            EventPublisher.mineAndSignWithGoBackend(eventJSON: jsonStr, secretKey: secretKey, difficulty: difficulty, maxAttempts: maxAttempts)
        }.value
    }
}
