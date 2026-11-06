import Foundation

/// Runs "Delete Account" for the owner (rules and order in `LeaveNostr`):
/// sign and send the blank profile, sign and send the erase request, then
/// wipe this device. Nothing is deleted unless both events were signed by
/// the owner's key (local key or remote signer).
@MainActor
enum LeaveNostrService {
    enum SignFailure: Error, Equatable {
        case noOwner
        case profileNotSigned
        case eraseNotSigned

        var message: String {
            switch self {
            case .noOwner:
                return "There is no account on this device to delete."
            case .profileNotSigned, .eraseNotSigned:
                return "The erase request could not be signed, so nothing was sent and nothing was deleted. "
                    + "If you use a remote signer, open it and approve the request, then try again."
            }
        }
    }

    /// How long to wait for relays to answer before the wipe goes ahead.
    static let answerWait: UInt64 = 15_000_000_000

    /// Steps 1 and 2: signs both events as the owner, sends them to the vault
    /// on this device and to every relay the account uses, and waits for the
    /// relays' answers (up to `answerWait`). Returns how the erase request fared.
    static func sendEraseRequest(configService: ConfigService, nostrService: NostrService) async -> Result<LeaveNostr.Tally, SignFailure> {
        let ownerHex = nostrService.ownerHexPubkey
        guard !configService.config.ownerNpub.isEmpty, !ownerHex.isEmpty else { return .failure(.noOwner) }

        guard let profile = await nostrService.signEventAsync(kind: 0, content: LeaveNostr.blankProfileContent, forceOwner: true),
              LeaveNostr.signedAsAsked(pubkey: profile.pubkey, kind: profile.kind, content: profile.content, tags: profile.tags,
                                       ownerHex: ownerHex, askedKind: 0, askedContent: LeaveNostr.blankProfileContent, askedTags: []),
              ProfileSaveGuard.mayPublish(kind: profile.kind, signedPubkey: profile.pubkey, profilePubkey: ownerHex, formLoadedFor: ownerHex) else {
            RelayProcessManager.shared.addLog("Delete Account: blank profile not signed; nothing sent or deleted", level: "ERROR")
            return .failure(.profileNotSigned)
        }
        guard let erase = await nostrService.signEventAsync(kind: 62, content: LeaveNostr.vanishContent,
                                                            tags: LeaveNostr.vanishTags, forceOwner: true),
              LeaveNostr.signedAsAsked(pubkey: erase.pubkey, kind: erase.kind, content: erase.content, tags: erase.tags,
                                       ownerHex: ownerHex, askedKind: LeaveNostr.vanishKind, askedContent: LeaveNostr.vanishContent,
                                       askedTags: LeaveNostr.vanishTags) else {
            RelayProcessManager.shared.addLog("Delete Account: erase request not signed; nothing sent or deleted", level: "ERROR")
            return .failure(.eraseNotSigned)
        }

        let config = configService.config
        let relays = LeaveNostr.relays(write: config.writeRelays, read: config.readRelays, dm: config.dmRelays,
                                       own: config.ownPublicRelays, blocked: config.blockedRelays)
        // The vault on this device first (it is wiped in step 3 either way).
        nostrService.postEvent(profile, directBroadcast: false)
        nostrService.postEvent(erase, directBroadcast: false)
        _ = await send(profile, to: relays, nostrService: nostrService)
        let tally = await send(erase, to: relays, nostrService: nostrService)
        RelayProcessManager.shared.addLog("Delete Account: \(tally.summary)", level: "INFO")
        return .success(tally)
    }

    /// Step 3: disconnects every remote signer (the keys stay in the signer),
    /// stops the vault, runs the Factory Reset wipe (key, vault data, config,
    /// keychain items, notifications) and then deletes what that leaves
    /// (`AppDataWipe`: caches, settings). The Mac app then exits at once, so
    /// nothing in memory is saved back on the way out; iOS shows setup and
    /// sweeps twice more (3 s, 10 s) after anything still running has written its caches.
    static func wipeThisDevice(configService: ConfigService, relayManager: RelayProcessManager) {
        for npub in Array(configService.config.accountBunkerConfigs.keys) {
            configService.removeBunkerConfig(forNpub: npub)
        }
        NIP46Service.dropSession(signerKey: NIP46Service.activeSignerKey())
        NIP46Service.shared.disconnect()
        let appSupport = configService.relayDataDir.deletingLastPathComponent()
        let ownerHex = NostrService.shared.ownerHexPubkey
        relayManager.stopRelay {
            Task { @MainActor in
                configService.resetApp()
                forgetCachesInMemory()
                AppDataWipe.clearRest(appSupport: appSupport)
                #if canImport(AppKit)
                exit(0)
                #else
                for wait: UInt64 in [3, 7] {
                    try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                    AppDataWipe.sweepCaches(appSupport: appSupport, forgetting: ownerHex)
                }
                #endif
            }
        }
    }

    /// Empties the caches that running services write back to disk on a
    /// timer or when the app goes to the background (profiles and relay
    /// lists, the feed snapshot), so the sweep after the reset stays swept.
    private static func forgetCachesInMemory() {
        let nostr = NostrService.shared
        nostr.profiles = [:]
        nostr.relayLists = [:]
        nostr.outboxRelays = [:]
        nostr.dmRelayLists = [:]
        nostr.serverLists = [:]
        FeedService.shared.notes = []
    }

    /// Sends `event` to `relays` and waits until each answered (or timed out)
    /// or `answerWait` passed.
    private static func send(_ event: NostrEvent, to relays: [String], nostrService: NostrService) async -> LeaveNostr.Tally {
        let collector = Collector(total: relays.count)
        guard !relays.isEmpty else { return collector.tally }
        let dict: [String: Any] = [
            "id": event.id, "pubkey": event.pubkey, "created_at": event.created_at,
            "kind": event.kind, "tags": event.tags, "content": event.content, "sig": event.sig,
        ]
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            collector.done = done
            nostrService.broadcastRawEvent(dict, to: relays) { url, ok, message in
                MainActor.assumeIsolated { collector.record(url: url, ok: ok, message: message) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: answerWait)
                collector.finish()
            }
        }
        return collector.tally
    }

    @MainActor
    private final class Collector {
        var tally: LeaveNostr.Tally
        var answered = 0
        var done: CheckedContinuation<Void, Never>?

        init(total: Int) { tally = LeaveNostr.Tally(total: total) }

        func record(url: String, ok: Bool, message: String) {
            guard done != nil else { return }
            answered += 1
            // "timeout" and "connection failed" are the broadcaster's own words
            // for a relay that never answered; anything else is the relay's no.
            if ok {
                tally.accepted.append(url)
            } else if !LeaveNostr.unanswered.contains(message) {
                tally.refused.append(url)
                RelayProcessManager.shared.addLog("Delete Account: \(url) refused: \(message)", level: "WARN")
            }
            if answered >= tally.total { finish() }
        }

        func finish() {
            done?.resume()
            done = nil
        }
    }
}
