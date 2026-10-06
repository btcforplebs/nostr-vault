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
            case "dm", "giftwrap": return prefs.dms
            case "zap":            return prefs.zaps
            // Zaps Only mode hard-disables reaction notifications regardless of the stored preference.
            case "reaction":       return !ConfigService.shared.config.zapsOnlyMode && prefs.reactions
            case "repost":         return prefs.reposts
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
        guard NotificationPolicy.authorMayNotify(author, type: type,
                                                 trusted: FeedService.shared.relayTabTrustedPubkeys(),
                                                 own: own) else { return }

        // One summary per absence: record it as soon as it is cleared to fire,
        // so the next background wake's round does not repeat it.
        if type == "summary" { NotificationActivityLog.recordCatchUpSummary() }

        if type == "dm" || type == "giftwrap" {
            announceDM(id: id, type: type, author: author, recipientHex: recipientHex, npub: npub)
            return
        }

        let name = author.isEmpty ? nil : NostrService.shared.profiles[author]?.bestName
        deliver(id: id, type: type, name: name, preview: preview, npub: npub)
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
            let text = opened.flatMap { NotificationPolicy.dmPreview($0.message.content) } ?? ""
            deliver(id: id, type: type, name: name, preview: text, npub: npub)
        }
    }

    /// Looks up the post first for a notification about one, so a tap opens it
    /// with nothing left to load. The relay on this device has just stored the
    /// event, so the lookup takes milliseconds.
    private func deliver(id: String, type: String, name: String?, preview: String, npub: String) {
        guard Self.opensNote(type) else {
            show(id: id, type: type, name: name, preview: preview, npub: npub, note: nil)
            return
        }
        Task { @MainActor in
            let note = await Self.resolveNote(type: type, id: id)
            self.show(id: id, type: type, name: name, preview: preview, npub: npub, note: note)
        }
    }

    private func show(id: String, type: String, name: String?, preview: String, npub: String, note: FeedNote?) {
        if appInForeground {
            showInAppBanner(id: id, type: type, name: name, preview: preview, npub: npub, note: note)
        } else {
            post(id: id, type: type, name: name, preview: preview, npub: npub, note: note)
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
        case "summary":
            return ("Catching up", preview.isEmpty ? "New activity while you were away" : preview)
        default:
            return ("New activity", "Tap to view")
        }
    }

    /// Shows the in-app drop-down banner (RelayActivityBanner) for activity that arrives
    /// while the app is foregrounded, tappable to jump straight to the relevant tab/note,
    /// with the same notification sound the system push would have played.
    private func showInAppBanner(id: String, type: String, name: String?, preview: String, npub: String, note: FeedNote?) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)
        let (icon, color) = iconAndColor(for: type)
        RelayActivityNotificationManager.shared.show(icon: icon, title: title, body: body, color: color) {
            Self.navigate(type: type, id: id, npub: npub, note: note)
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
        case "dm", "giftwrap": return ("envelope.fill", Color.blue)
        case "zap":            return ("bolt.fill", Color.orange)
        case "reaction":       return ("heart.fill", Color.pink)
        case "repost":         return ("arrow.2.squarepath", Color(red: 0.2, green: 0.8, blue: 0.6))
        case "summary":        return ("clock.arrow.circlepath", Color.gray)
        default:               return ("bell.fill", Color.gray)
        }
    }

    /// Navigates to the destination for a tapped relay-event notification. Called from
    /// AppDelegate's notification-tap handler via the `notif_type`/`notif_id`/`notif_npub`
    /// userInfo this service attaches in `post()`. Switches to the tagged account first —
    /// without this, tapping a notification for a non-active whitelisted account would
    /// open the right tab but show the wrong account's data.
    static func navigate(type: String, id: String, npub: String? = nil, note: FeedNote? = nil) {
        let currentNpub = ConfigService.shared.config.activeAccountNpub.isEmpty
            ? ConfigService.shared.config.ownerNpub
            : ConfigService.shared.config.activeAccountNpub
        if let npub, !npub.isEmpty, npub != currentNpub {
            ConfigService.shared.switchActiveAccount(to: npub)
        }
        // Opens the post itself: the mention or reply, or your note that was
        // reacted to, zapped or reposted. It was looked up when the notification
        // went out, so there is normally nothing to wait for. This used to land
        // on the Relay tab and search its list for up to 10 s before falling
        // back to a sheet that fetched the post all over again.
        switch type {
        case "mention", "reply", "repost", "reaction", "zap":
            if let note {
                NotificationNoteOpen.request(note)
                return
            }
            Task { @MainActor in
                if let found = await resolveNote(type: type, id: id, waitForRelay: true) {
                    NotificationNoteOpen.request(found)
                } else {
                    // Nothing to open: a zap on your profile rather than a
                    // post, or a post this device no longer holds.
                    let list: Notification.Name = type == "zap" ? .havenOpenRelayZaps
                        : type == "reaction" ? .havenOpenRelayLikes : .havenOpenRelayNotes
                    NotificationCenter.default.post(name: list, object: nil)
                }
            }
        case "dm", "giftwrap":
            // Straight to the conversation when the inbox has the message;
            // the object is the counterparty the inbox should open.
            let peer = DMService.shared.message(withEventId: id)?.conversationId
            NotificationCenter.default.post(name: .havenOpenDMInbox, object: peer)
        default:
            break
        }
    }

    private func post(id: String, type: String, name: String?, preview: String, npub: String, note: FeedNote?) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let sound = NotificationSound(rawValue: ConfigService.shared.config.notificationSoundName) ?? .defaultSound
        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound.systemSoundName))
        content.categoryIdentifier = "RELAY_EVENT"
        var userInfo: [String: Any] = ["notif_type": type, "notif_id": id, "notif_npub": npub]
        if let note, let data = try? JSONEncoder().encode(note) {
            userInfo[Self.noteUserInfoKey] = data
        }
        content.userInfo = userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "haven-relay-\(id)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - The post a notification opens

extension LocalNotificationService {
    /// userInfo key for the encoded `FeedNote` a tap opens.
    static let noteUserInfoKey = "notif_note"

    static func opensNote(_ type: String) -> Bool {
        ["mention", "reply", "repost", "reaction", "zap"].contains(type)
    }

    /// The post a notification is about: the event itself for a mention or
    /// reply, the note it points at for a reaction, zap or repost.
    /// `waitForRelay` gives a tap that cold-launched the app time for the
    /// relay on this device to start.
    static func resolveNote(type: String, id: String, waitForRelay: Bool = false) async -> FeedNote? {
        let feed = FeedService.shared
        if type == "mention" || type == "reply", let known = feed.findNote(id: id) {
            return known
        }
        if waitForRelay {
            for _ in 0..<50 where !RelayProcessManager.shared.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let event = await LocalEventLookup.events(ids: [id]).first else { return nil }
        if type == "mention" || type == "reply" {
            return FeedNote(eventJSON: event)
        }
        // A repost carries the note it shares in its content.
        if type == "repost", let content = event["content"] as? String,
           let data = content.data(using: .utf8),
           let embedded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let note = FeedNote(eventJSON: embedded) {
            return note
        }
        // NIP-25 puts the reacted-to note in the last `e` tag; a zap receipt
        // and a repost have one.
        let eTags = ((event["tags"] as? [[String]]) ?? []).filter { $0.count >= 2 && $0[0] == "e" }
        guard let targetId = (type == "reaction" ? eTags.last : eTags.first)?[1] else { return nil }
        if let known = feed.findNote(id: targetId) { return known }
        return await LocalEventLookup.events(ids: [targetId]).first.flatMap(FeedNote.init(eventJSON:))
    }
}

/// A post a notification tap opens, parked until the feed can push it: a tap
/// that launches the app is handled before the feed exists.
@MainActor
enum NotificationNoteOpen {
    static var pending: FeedNote?

    static func request(_ note: FeedNote) {
        pending = note
        // iOS switches to the Feed tab on havenOpenFeed, macOS on this one.
        NotificationCenter.default.post(name: .havenOpenFeed, object: nil)
        NotificationCenter.default.post(name: .havenOpenNotificationNote, object: nil)
    }

    static func consume() -> FeedNote? {
        defer { pending = nil }
        return pending
    }
}

/// Reads events by id from the relay on this device, which holds everything a
/// notification is about: the inbox has the mention, reaction or zap, and the
/// outbox has your note it points at.
@MainActor
enum LocalEventLookup {
    static func events(ids: [String], timeout: TimeInterval = 1.5) async -> [[String: Any]] {
        guard !ids.isEmpty, RelayProcessManager.shared.isRunning else { return [] }
        let base = ConfigService.shared.config.nostrURL
        var found: [[String: Any]] = []
        for url in [base + "/inbox", base].compactMap(URL.init(string:)) {
            found += await query(url, ids: ids, timeout: timeout)
            if Set(found.compactMap { $0["id"] as? String }).isSuperset(of: ids) { break }
        }
        return found
    }

    private final class Query {
        let client = WebSocketClient()
        let subId = "notif-\(UUID().uuidString.prefix(6))"
        var found: [[String: Any]] = []
        var sent = false
        var finished = false
        var bag = Set<AnyCancellable>()
    }

    private static func query(_ url: URL, ids: [String], timeout: TimeInterval) async -> [[String: Any]] {
        await withCheckedContinuation { continuation in
            let q = Query()
            q.client.isTemporary = true
            let finish = {
                guard !q.finished else { return }
                q.finished = true
                q.bag.removeAll()
                q.client.disconnect()
                continuation.resume(returning: q.found)
            }
            q.client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard let data = message.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          json.count >= 2, json[1] as? String == q.subId else { return }
                    switch json[0] as? String {
                    case "EVENT":
                        if json.count >= 3, let event = json[2] as? [String: Any] { q.found.append(event) }
                    case "EOSE", "CLOSED":
                        finish()
                    default:
                        break
                    }
                }
                .store(in: &q.bag)
            q.client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected, !q.sent else { return }
                    q.sent = true
                    let req: [Any] = ["REQ", q.subId, ["ids": ids]]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let text = String(data: data, encoding: .utf8) {
                        q.client.send(text: text)
                    }
                }
                .store(in: &q.bag)
            q.client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}

extension FeedNote {
    /// A note from a raw event object, as a relay sends it.
    init?(eventJSON event: [String: Any]) {
        guard let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String,
              let createdAt = (event["created_at"] as? NSNumber)?.int64Value,
              let kind = (event["kind"] as? NSNumber)?.intValue else { return nil }
        self.init(id: id, pubkey: pubkey, content: content,
                  createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                  tags: event["tags"] as? [[String]] ?? [], kind: kind)
    }
}
