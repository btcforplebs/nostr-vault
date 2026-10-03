import AVFoundation
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

    private func deliver(id: String, type: String, name: String?, preview: String, npub: String) {
        if appInForeground {
            showInAppBanner(id: id, type: type, name: name, preview: preview, npub: npub)
        } else {
            post(id: id, type: type, name: name, preview: preview, npub: npub)
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
    private func showInAppBanner(id: String, type: String, name: String?, preview: String, npub: String) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)
        let (icon, color) = iconAndColor(for: type)
        RelayActivityNotificationManager.shared.show(icon: icon, title: title, body: body, color: color) {
            Self.navigate(type: type, id: id, npub: npub)
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
    static func navigate(type: String, id: String, npub: String? = nil) {
        let currentNpub = ConfigService.shared.config.activeAccountNpub.isEmpty
            ? ConfigService.shared.config.ownerNpub
            : ConfigService.shared.config.activeAccountNpub
        if let npub, !npub.isEmpty, npub != currentNpub {
            ConfigService.shared.switchActiveAccount(to: npub)
        }
        // Every relay-event notification lands on that event in the Relay tab.
        // Mentions and replies used to open the thread sheet over the Feed tab
        // instead, and the others only picked a filter without finding the post.
        switch type {
        case "mention", "reply", "repost":
            NotificationCenter.default.post(name: .havenOpenRelayNotes, object: nil)
            RelayFocus.request(type: type, eventId: id)
        case "reaction":
            NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
            RelayFocus.request(type: type, eventId: id)
        case "zap":
            NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
            RelayFocus.request(type: type, eventId: id)
        case "dm", "giftwrap":
            // Straight to the conversation when the inbox has the message;
            // the object is the counterparty the inbox should open.
            let peer = DMService.shared.message(withEventId: id)?.conversationId
            NotificationCenter.default.post(name: .havenOpenDMInbox, object: peer)
        default:
            break
        }
    }

    private func post(id: String, type: String, name: String?, preview: String, npub: String) {
        let (title, body) = titleAndBody(type: type, name: name, preview: preview)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let sound = NotificationSound(rawValue: ConfigService.shared.config.notificationSoundName) ?? .defaultSound
        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound.systemSoundName))
        content.categoryIdentifier = "RELAY_EVENT"
        content.userInfo = ["notif_type": type, "notif_id": id, "notif_npub": npub]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "haven-relay-\(id)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}
