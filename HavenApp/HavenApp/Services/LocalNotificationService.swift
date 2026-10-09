import AVFoundation
import Combine
import Foundation
import SwiftUI
import UserNotifications

/// Fires notifications from the embedded relay's `🔔NOTIFY|` log markers — a system push
/// while backgrounded, or an in-app banner (RelayActivityBanner) with sound while foregrounded
/// (a system notification can't banner sensibly over an actively-open app).
/// Mirrors Android's LocalNotificationService.kt — no push server required.
///
/// Feed via RelayProcessManager.applyBatchedUpdate() whenever it sees a
/// `🔔NOTIFY|` line in the relay's stdout pipe.
@MainActor
final class LocalNotificationService {
    static let shared = LocalNotificationService()
    private init() {}

    /// True while the app is foregrounded. Set by SceneDelegate.
    var appInForeground: Bool = false

    private var soundPlayer: AVAudioPlayer?
    private var seen = Set<String>()
    private let maxSeen = 500
    private let seenLock = NSLock()

    /// Whether a catch-up summary may fire right now: never over an open app,
    /// and only once per genuine absence (NotificationPolicy.minimumAbsence).
    private var catchUpSummaryAllowed: Bool {
        guard !appInForeground else { return false }
        return NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: Date(),
            lastForegroundAt: NotificationActivityLog.lastForegroundAt,
            lastAnnouncedAt: NotificationActivityLog.lastCatchUpSummaryAt
        )
    }

    // MARK: - Entry point

    /// Called on the main actor from RelayProcessManager.applyBatchedUpdate()
    /// with the text after the `🔔NOTIFY|` prefix.
    func handle(_ markerBody: String) {
        let pushEnabled = ConfigService.shared.config.enablePushNotifications

        // preview is always last and may contain spaces/pipes — split it off first
        let previewKey = "|preview="
        let head: String
        let preview: String
        if let r = markerBody.range(of: previewKey) {
            head = String(markerBody[markerBody.startIndex..<r.lowerBound])
            preview = String(markerBody[r.upperBound...])
        } else {
            head = markerBody
            preview = ""
        }

        var fields: [String: String] = [:]
        for part in head.split(separator: "|") {
            let s = String(part)
            if let eq = s.firstIndex(of: "=") {
                fields[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }        }

        guard let type = fields["type"] else { return }
        guard pushEnabled || NotificationPolicy.allowsWithPushOff(type: type, appInForeground: appInForeground) else { return }
        let author = fields["author"] ?? ""

        // The catch-up backlog "summary" marker has no per-event id (it isn't
        // one event) — synthesize one so it isn't rejected by the empty-id
        // check that every other type relies on for dedup.
        let rawId = fields["id"] ?? ""
        guard type == "summary" || !rawId.isEmpty else { return }
        let id = rawId.isEmpty ? "summary-\(Int(Date().timeIntervalSince1970))" : rawId

        guard markSeen(id) else { return }

        // The inbox is shared across every whitelisted account on this device, so the
        // marker's `recipient` (the whitelisted hex pubkey it was actually tagged for —
        // see haven-go's classifyInboxEvent) tells us whose prefs to check. Falling back
        // to whichever account happens to be active in the UI would apply the wrong
        // account's settings whenever the event isn't for the currently-active one.
        let recipientHex = fields["recipient"] ?? ""
        let npub = resolveNpub(forHex: recipientHex) ?? (
            ConfigService.shared.config.activeAccountNpub.isEmpty
                ? ConfigService.shared.config.ownerNpub
                : ConfigService.shared.config.activeAccountNpub
        )
        let prefs = PushNotificationService.shared.preferencesForAccount(npub)

        let allowed: Bool = {
            switch type {
            case "mention":        return prefs.mentions
            case "reply":          return prefs.replies
            // A quote of your note is a mention of you, so the Mentions switch governs it.
            case "quote":          return prefs.mentions
            case "dm", "giftwrap": return prefs.dms
            case "zap":            return prefs.zaps
            // Zaps Only mode hard-disables reaction notifications regardless of the stored preference.
            case "reaction":       return !ConfigService.shared.config.zapsOnlyMode && prefs.reactions
            case "repost":         return prefs.reposts
            case "follow":         return prefs.follows
            // The catch-up backlog count spans every type, so no per-type
            // preference governs it — but turning all of them off must still
            // silence it. It is also meaningless while the app is open: it
            // announces activity you missed, and you missed nothing. And the
            // relay re-runs this round on every background wake, so it is only
            // "while you were away" if you actually were — see catchUpSummaryAllowed.
            case "summary":        return prefs.wantsAnything && catchUpSummaryAllowed
            default:               return false
            }
        }()
        guard allowed else { return }
        // Nothing from outside your Web of Trust: those were the spam alerts.
        let own: Set<String> = [recipientHex, NostrService.shared.activeHexPubkey]
        let trusted = FeedService.shared.relayTabTrustedPubkeys()
        guard NotificationPolicy.authorMayNotify(author, type: type, trusted: trusted, own: own) else { return }

        // One summary per absence: record it as soon as it is cleared to fire,
        // so the next background wake's round does not repeat it.
        if type == "summary" { NotificationActivityLog.recordCatchUpSummary() }

        if type == "dm" || type == "giftwrap" {
            announceDM(id: id, type: type, author: author, recipientHex: recipientHex, npub: npub)
            return
        }

        if type == "follow" {
            if NotificationPolicy.followIsNamed(author, trusted: trusted) {
                announceFollow(follower: author, npub: npub)
            } else {
                announceFoldedFollow(follower: author, npub: npub)
            }
            return
        }

        let name = author.isEmpty ? nil : NostrService.shared.profiles[author]?.bestName
        Task { @MainActor in
            let carried = await Self.carriedNotes(type: type, id: id)
            // The relay hands over the note's raw text, so a mention would read
            // `nostr:npub1…`. A reaction's preview is its emoji, not note text.
            let text = type == "reaction" ? preview : NostrContentFormatter.resolveMentionsPlainText(preview)
            deliver(id: id, type: type, name: name, preview: text, npub: npub, carried: carried)
        }
    }

    /// How long the on-device lookup may hold a notification back. The relay
    /// is in-process and answers in milliseconds; this only bounds a socket
    /// that never does.
    private static let carriedLookupTimeout: TimeInterval = 1.5

    /// The event this notification is about, and for a like, zap or repost the
    /// post it was on, as userInfo entries (see `NotificationNote`). Read from
    /// this device's relay, which stored the event before raising the marker.
    /// Empty when the relay does not answer; the tap then loads by id.
    private static func carriedNotes(type: String, id: String) async -> [String: String] {
        var carried: [String: String] = [:]
        let found = await localEvents(ids: [id])
        guard let event = found[id] else { return carried }
        carried[NotificationNote.eventKey] = event
        guard let parsed = NotificationNote.decode(event),
              let targetId = NotificationNote.targetId(type: type, tags: parsed.tags) else { return carried }
        if let target = await localEvents(ids: [targetId])[targetId] {
            carried[NotificationNote.targetKey] = target
        } else if let note = FeedService.shared.findNote(id: targetId), note.kind != 6,
                  let target = NotificationNote.encode([
                      "id": note.id, "pubkey": note.pubkey, "kind": note.kind, "tags": note.tags,
                      "content": note.content, "created_at": Int64(note.createdAt.timeIntervalSince1970)
                  ]) {
            carried[NotificationNote.targetKey] = target
        }
        return carried
    }

    /// Events by id from this device's relay: the inbox, where mentions,
    /// likes and zaps are stored, and the outbox, which holds your own posts.
    /// Finishes when both routes have answered.
    private static func localEvents(ids: [String]) async -> [String: String] {
        let base = ConfigService.shared.config.nostrURL
        let routes = [base, base + "/inbox"].compactMap { URL(string: $0) }
        guard !routes.isEmpty, !ids.isEmpty else { return [:] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: String], Never>) in
            var found: [String: String] = [:]
            var finished = 0
            var resumed = false
            var clients: [WebSocketClient] = []
            var subs = Set<AnyCancellable>()

            // Everything below runs on the main queue, so no lock.
            func finish() {
                guard !resumed else { return }
                resumed = true
                clients.forEach { $0.disconnect() }
                subs.removeAll()
                continuation.resume(returning: found)
            }

            for url in routes {
                let client = WebSocketClient()
                client.isTemporary = true
                clients.append(client)
                let subId = "notif-\(UUID().uuidString.prefix(6))"
                client.messageSubject
                    .receive(on: DispatchQueue.main)
                    .sink { message in
                        guard let data = message.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              let type = json.first as? String,
                              json[safe: 1] as? String == subId else { return }
                        if type == "EVENT", let dict = json[safe: 2] as? [String: Any],
                           let id = dict["id"] as? String, ids.contains(id),
                           let encoded = NotificationNote.encode(dict) {
                            found[id] = encoded
                        } else if type == "EOSE" || type == "CLOSED" {
                            finished += 1
                            if finished >= routes.count || found.count == ids.count { finish() }
                        }
                    }
                    .store(in: &subs)
                client.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        switch state {
                        case .connected:
                            let req = ["REQ", subId, ["ids": ids, "limit": ids.count]] as [Any]
                            if let data = try? JSONSerialization.data(withJSONObject: req),
                               let text = String(data: data, encoding: .utf8) {
                                client.send(text: text)
                            }
                        case .error:
                            finished += 1
                            if finished >= routes.count { finish() }
                        default:
                            break
                        }
                    }
                    .store(in: &subs)
                client.connect(url: url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + carriedLookupTimeout) { finish() }
        }
    }

    /// How long a follow notification waits for the follower's profile.
    private static let followProfileTimeout: TimeInterval = 3

    /// A new follower is usually a stranger whose profile isn't loaded yet;
    /// "Someone followed you" says nothing, so fetch the name first. The
    /// follower's pubkey rides as the id so a tap can open their profile.
    private func announceFollow(follower: String, npub: String) {
        Task { @MainActor in
            let nostr = NostrService.shared
            if nostr.profiles[follower] == nil {
                nostr.fetchMissingProfiles(for: [follower])
                let deadline = Date().addingTimeInterval(Self.followProfileTimeout)
                while nostr.profiles[follower] == nil, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            deliver(id: follower, type: "follow", name: nostr.profiles[follower]?.bestName, preview: "", npub: npub)
        }
    }

    /// Serialises the folded alert's read-then-replace, so two strangers
    /// arriving together are both counted.
    private var foldedFollowChain: Task<Void, Never>?

    /// A stranger's follow joins one nameless "N new followers" alert per
    /// account (NotificationPolicy.followIsNamed). The count and the latest
    /// strangers ride in its userInfo, so the count survives a relaunch, and
    /// once the alert is tapped or swiped away the next stranger starts it
    /// over. Only the first stranger makes a sound: each later one just
    /// changes the number, so a burst of follows buzzes the phone once.
    private func announceFoldedFollow(follower: String, npub: String) {
        guard NotificationPolicy.isPubkeyHex(follower) else { return }
        let previous = foldedFollowChain
        foldedFollowChain = Task { @MainActor in
            await previous?.value
            let id = "followers-\(npub)"
            let showing = await Self.foldedFollowersShowing(identifier: "haven-relay-\(id)")
            let folded = NotificationPolicy.foldedFollowers(showing: showing, adding: follower)
            let (title, body) = NotificationPolicy.foldedFollowersText(count: folded.count)
            let extra: [String: Any] = [Self.foldedFollowersKey: folded.members,
                                        Self.foldedFollowerCountKey: folded.count]
            if appInForeground {
                showInAppBanner(id: id, type: "followers", title: title, body: body, npub: npub)
                // The alert waiting in Notification Center still counts too,
                // or its number would go backwards after the next stranger.
                if showing.isShowing {
                    await post(id: id, type: "followers", title: title, body: body, npub: npub, extra: extra, quiet: true)
                }
            } else {
                await post(id: id, type: "followers", title: title, body: body, npub: npub,
                           extra: extra, quiet: showing.isShowing)
            }
        }
    }

    private static let foldedFollowersKey = "notif_followers"
    private static let foldedFollowerCountKey = "notif_follower_count"
    /// A replacement that only updates what is on screen: no sound, no banner.
    static let quietKey = "notif_quiet"

    /// What the folded alert on screen (or about to be) already counts.
    private static func foldedFollowersShowing(identifier: String) async -> NotificationPolicy.FoldedFollowers {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .first { $0.identifier == identifier }?.content.userInfo
        let delivered = await center.deliveredNotifications()
            .first { $0.request.identifier == identifier }?.request.content.userInfo
        guard let info = pending ?? delivered else { return .init() }
        let members = (info[foldedFollowersKey] as? [String]) ?? []
        return .init(members: members, count: (info[foldedFollowerCountKey] as? Int) ?? members.count)
    }

    /// How long a DM marker waits for the inbox to decrypt its message.
    private static let dmOpenTimeout: TimeInterval = 3
    /// The wait while a DM thread is open: a slow decrypt there must end with
    /// the message appearing in the thread, not a generic alert first.
    private static let dmOpenTimeoutInThread: TimeInterval = 15

    /// A gift wrap is signed by a throwaway key, so its marker cannot say who
    /// wrote it — not even when it was you: every DM you send also wraps a copy
    /// to yourself, and that copy lands in your own inbox. Copies this device
    /// sent are known by id; for the rest the inbox decrypts the message a
    /// moment later, so wait for that, then drop your own copies and show
    /// the real sender and text. If it never opens (another account, an
    /// offline signer) the generic line still goes out.
    private func announceDM(id: String, type: String, author: String, recipientHex: String, npub: String) {
        // A NIP-04 DM names its author in the clear.
        if !author.isEmpty, author.lowercased() == recipientHex.lowercased() { return }
        if DMService.shared.isOwnSentWrap(id) { return }

        Task { @MainActor in
            let inThread = appInForeground && DMService.shared.visibleConversation != nil
            let opened = await DMService.shared.waitForMessage(
                withEventId: id,
                timeout: inThread ? Self.dmOpenTimeoutInThread : Self.dmOpenTimeout
            )
            if let opened {
                if opened.message.isFromMe { return }
                // The conversation is already on screen.
                if appInForeground, DMService.shared.visibleConversation == opened.conversationId { return }
            }
            let sender = opened?.message.senderPubkey ?? author
            let name = sender.isEmpty ? nil : NostrService.shared.profiles[sender]?.bestName
            let text = opened.flatMap {
                NotificationPolicy.dmPreview(NostrContentFormatter.resolveMentionsPlainText($0.message.content))
            } ?? ""
            deliver(id: id, type: type, name: name, preview: text, npub: npub)
        }
    }

    private func deliver(id: String, type: String, name: String?, preview: String, npub: String,
                         carried: [String: String] = [:]) {
        if appInForeground {
            showInAppBanner(id: id, type: type, name: name, preview: preview, npub: npub, carried: carried)
        } else {
            post(id: id, type: type, name: name, preview: preview, npub: npub, carried: carried)
        }
    }

    // MARK: - Private

    /// Maps a whitelisted account's hex pubkey (from the marker's `recipient` field) back
    /// to its npub, so callers can resolve prefs/navigation without guessing. Returns nil
    /// for an empty/unmatched hex (e.g. the account-agnostic `summary` marker).
    private func resolveNpub(forHex hex: String) -> String? {
        guard !hex.isEmpty else { return nil }
        return ConfigService.shared.allAccountNpubs.first {
            Bech32.decode($0)?.hexString.lowercased() == hex.lowercased()
        }
    }

    private func markSeen(_ id: String) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        guard seen.insert(id).inserted else { return false }
        if seen.count > maxSeen {
            seen = Set(seen.dropFirst(maxSeen / 2))
        }
        return true
    }

    private func titleAndBody(type: String, name: String?, preview: String) -> (String, String) {
        let who = name ?? "Someone"
        switch type {
        case "mention":
            return ("\(who) mentioned you",
                    preview.isEmpty ? "You were mentioned in a note" : preview)
        case "reply":
            return ("\(who) replied to your note",
                    preview.isEmpty ? "Tap to view the reply" : preview)
        case "quote":
            return ("\(who) quoted your note",
                    preview.isEmpty ? "Tap to view the quote" : preview)
        case "dm", "giftwrap":
            return (name != nil ? "Message from \(who)" : "New message",
                    preview.isEmpty ? "You have a new encrypted message" : preview)
        case "zap":
            return ("⚡ New zap",
                    name != nil ? "\(who) zapped you" : "You received a zap")
        case "reaction":
            return ("\(who) reacted \(preview.isEmpty ? "❤️" : preview)",
                    "Tap to view your note")
        case "repost":
            return ("\(who) reposted your note", "Tap to view")
        case "follow":
            return ("\(who) followed you", "Tap to see their profile")
        case "summary":
            return ("Catching up", preview.isEmpty ? "New activity while you were away" : preview)
        default:
            return ("New activity", "Tap to view")
        }
    }

    /// Shows the in-app drop-down banner (RelayActivityBanner) for activity that arrives
    /// while the app is foregrounded, tappable to jump straight to the relevant tab/note,
    /// with the same notification sound the system push would have played.
    private func showInAppBanner(id: String, type: String, name: String?, preview: String, npub: String,
                                 carried: [String: String]) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)
        showInAppBanner(id: id, type: type, title: title, body: body, npub: npub, carried: carried)
    }

    private func showInAppBanner(id: String, type: String, title: String, body: String, npub: String,
                                 carried: [String: String] = [:]) {
        let (icon, color) = iconAndColor(for: type)
        RelayActivityNotificationManager.shared.show(icon: icon, title: title, body: body, color: color) {
            Self.navigate(type: type, id: id, npub: npub, carried: carried)
        }
        playSound()
    }

    private func playSound() {
        let sound = NotificationSound(rawValue: ConfigService.shared.config.notificationSoundName) ?? .defaultSound
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "mp3") else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            soundPlayer = player // retain until playback finishes
            player.play()
        } catch {
            // Best-effort — a missing/unplayable sound shouldn't block the banner itself.
        }
    }

    private func iconAndColor(for type: String) -> (String, Color) {
        switch type {
        case "mention":        return ("at", Color.havenPurple)
        case "reply":          return ("arrowshape.turn.up.left.fill", Color.havenPurple)
        case "quote":          return ("quote.bubble.fill", Color.havenPurple)
        case "dm", "giftwrap": return ("envelope.fill", Color.blue)
        case "zap":            return ("bolt.fill", Color.orange)
        case "reaction":       return ("heart.fill", Color.pink)
        case "repost":         return ("arrow.2.squarepath", Color(red: 0.2, green: 0.8, blue: 0.6))
        case "follow", "followers": return ("person.badge.plus", Color.havenPurple)
        case "summary":        return ("clock.arrow.circlepath", Color.gray)
        default:               return ("bell.fill", Color.gray)
        }
    }

    /// Navigates to the destination for a tapped relay-event notification. Called from
    /// AppDelegate's notification-tap handler via the `notif_type`/`notif_id`/`notif_npub`
    /// userInfo this service attaches in `post()`. Switches to the tagged account first —
    /// without this, tapping a notification for a non-active whitelisted account would
    /// open the right tab but show the wrong account's data.
    static func navigate(type: String, id: String, npub: String? = nil, carried: [AnyHashable: Any] = [:]) {
        let currentNpub = ConfigService.shared.config.activeAccountNpub.isEmpty
            ? ConfigService.shared.config.ownerNpub
            : ConfigService.shared.config.activeAccountNpub
        if let npub, !npub.isEmpty, npub != currentNpub {
            ConfigService.shared.switchActiveAccount(to: npub)
        }
        #if os(iOS)
        // A post opens straight away in the Feed tab's thread view, from the
        // copy the notification carries. The Relay tab route below is left for
        // what has no post to open: a zap on your profile, or an alert raised
        // before notifications carried their post and naming a like by id only.
        if let open = NotificationOpen.destination(type: type, id: id, carried: carried) {
            NotificationOpen.pending = open
            NotificationCenter.default.post(name: .havenOpenFeed, object: nil)
            NotificationCenter.default.post(name: .havenOpenNotificationNote, object: nil)
            return
        }
        #endif
        // Every relay-event notification lands on that event in the Relay tab.
        // Mentions and replies used to open the thread sheet over the Feed tab
        // instead, and the others only picked a filter without finding the post.
        switch type {
        case "mention", "reply", "quote", "repost":
            NotificationCenter.default.post(name: .havenOpenRelayNotes, object: nil)
            RelayFocus.request(type: type, eventId: id)
        case "reaction":
            NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
            RelayFocus.request(type: type, eventId: id)
        case "zap":
            NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
            RelayFocus.request(type: type, eventId: id)
        case "follow":
            // The id is the follower's pubkey (announceFollow): their profile
            // opens over whatever tab is showing, and the Relay tab, if built,
            // switches to its Followers list behind it.
            NotificationCenter.default.post(name: .havenOpenRelayFollowers, object: nil)
            RelayFocus.request(type: "followers", eventId: "")
            NotificationCenter.default.post(name: .havenOpenProfile, object: id)
        case "followers":
            // The folded strangers' alert: their list, nobody named.
            NotificationCenter.default.post(name: .havenOpenRelayFollowers, object: nil)
            RelayFocus.request(type: "followers", eventId: "")
        case "dm", "giftwrap":
            // Straight to the conversation when the inbox has the message;
            // the object is the counterparty the inbox should open.
            let peer = DMService.shared.message(withEventId: id)?.conversationId
            NotificationCenter.default.post(name: .havenOpenDMInbox, object: peer)
        default:
            break
        }
    }

    private func post(id: String, type: String, name: String?, preview: String, npub: String,
                      carried: [String: String]) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)
        post(id: id, type: type, title: title, body: body, npub: npub, extra: carried)
    }

    private func post(id: String, type: String, title: String, body: String, npub: String,
                      extra: [String: Any] = [:], quiet: Bool = false) {
        Task { await post(id: id, type: type, title: title, body: body, npub: npub, extra: extra, quiet: quiet) }
    }

    /// Returns once the system has filed the request, so the folded alert's
    /// next read-back sees it (announceFoldedFollow).
    private func post(id: String, type: String, title: String, body: String, npub: String,
                      extra: [String: Any] = [:], quiet: Bool = false) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !quiet {
            let sound = NotificationSound(rawValue: ConfigService.shared.config.notificationSoundName) ?? .defaultSound
            content.sound = UNNotificationSound(named: UNNotificationSoundName(sound.systemSoundName))
        }
        content.categoryIdentifier = "RELAY_EVENT"
        content.userInfo = ["notif_type": type, "notif_id": id, "notif_npub": npub, Self.quietKey: quiet]
            .merging(extra) { current, _ in current }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "haven-relay-\(id)",
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("LocalNotificationService: Failed to show '\(type)' notification: \(error)")
        }
    }
}

/// The post a tapped notification opens, parked for the Feed tab. A tap on a
/// cold start lands before the Feed tab exists, so it waits here and the Feed
/// tab takes it when it appears.
enum NotificationOpen {
    /// The post itself, from the copy the notification carried.
    case note(FeedNote)
    /// Only its id: the Feed tab pushes a view that loads it.
    case id(String)

    @MainActor static var pending: NotificationOpen?

    /// Where a tap on a `type` notification goes. Nil when there is no post:
    /// a zap on a profile, or a like whose event the notification lacks.
    @MainActor
    static func destination(type: String, id: String, carried: [AnyHashable: Any]) -> NotificationOpen? {
        guard ["mention", "reply", "repost", "reaction", "zap"].contains(type) else { return nil }
        let event = (carried[NotificationNote.eventKey] as? String).flatMap(NotificationNote.decode)
        guard NotificationNote.opensTarget(type: type) else {
            return event.map { .note(FeedNote($0)) } ?? .id(id)
        }
        if let target = (carried[NotificationNote.targetKey] as? String).flatMap(NotificationNote.decode) {
            return .note(FeedNote(target))
        }
        guard let event, let targetId = NotificationNote.targetId(type: type, tags: event.tags) else { return nil }
        if let cached = FeedService.shared.findNote(id: targetId) { return .note(cached) }
        return .id(targetId)
    }
}

/// Pushed by the Feed tab for a notification that names its post by id only.
struct NotificationNoteRoute: Hashable {
    let id: String
}

extension FeedNote {
    init(_ event: NotificationNote.Event) {
        self.init(id: event.id, pubkey: event.pubkey, content: event.content,
                  createdAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt)),
                  tags: event.tags, kind: event.kind)
    }
}
