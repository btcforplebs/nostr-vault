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

    // MARK: - Catch-up batching

    // While > 0, individual notify-worthy markers are tallied instead of firing
    // their own banner/push — used by MacRelaySyncService so returning from
    // background and catching up on a backlog produces one "N new notifications"
    // summary instead of a flood of separate ones. Mirrors the Go relay's own
    // batchNotifier, which does the same thing for its live/negentropy catch-up.
    private var catchUpBatchDepth = 0
    private var catchUpBatchCount = 0

    /// Starts (or nests into) a catch-up batch. Call endCatchUpBatch() when done —
    /// nesting is supported defensively, but MacRelaySyncService only ever runs one
    /// round at a time.
    func beginCatchUpBatch() {
        catchUpBatchDepth += 1
    }

    /// Ends a catch-up batch. `settleDelay` gives already-in-flight NOTIFY markers
    /// (the relay logs them asynchronously as it processes each injected event) a
    /// moment to land before the summary fires — anything that arrives after this
    /// window falls back to notifying individually rather than being lost.
    func endCatchUpBatch(settleDelay: TimeInterval = 1.5) {
        guard catchUpBatchDepth > 0 else { return }
        catchUpBatchDepth -= 1
        guard catchUpBatchDepth == 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self = self else { return }
            let count = self.catchUpBatchCount
            self.catchUpBatchCount = 0
            guard count > 0 else { return }
            self.fireSummary(count: count)
        }
    }

    /// Posts a single "N new notifications" summary, reusing the existing
    /// `summary` type's title/body/icon.
    ///
    /// This path does not go through handle(), so it has to apply the same gates
    /// itself — it previously applied none of them, which meant the master
    /// Notifications switch, the per-account preferences and the "not while the
    /// app is open" rule all governed the relay's summary marker and none of
    /// them governed this one.
    private func fireSummary(count: Int) {
        guard ConfigService.shared.config.enablePushNotifications else { return }
        guard anyAccountWantsNotifications else { return }

        let preview = count == 1 ? "1 new notification" : "\(count) new notifications"
        let id = "summary-\(Int(Date().timeIntervalSince1970))"

        // Over an open app this is the in-app banner, as before: the events it
        // counts were tallied instead of banner'd individually, so staying
        // silent here would drop them entirely. Only the *system push* needs the
        // absence rule, because that is the one that repeats on every wake.
        if appInForeground {
            showInAppBanner(id: id, type: "summary", name: nil, preview: preview, npub: "")
            return
        }
        guard catchUpSummaryAllowed else { return }
        NotificationActivityLog.recordCatchUpSummary()
        post(id: id, type: "summary", name: nil, preview: preview, npub: "")
    }

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

    /// True when at least one account on this device wants any notification at
    /// all. The batch summary is account-agnostic (it spans every whitelisted
    /// account), so no single account's preferences can govern it.
    private var anyAccountWantsNotifications: Bool {
        let config = ConfigService.shared.config
        var npubs = ConfigService.shared.allAccountNpubs
        if npubs.isEmpty {
            npubs = [config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub]
        }
        return npubs.contains { PushNotificationService.shared.preferencesForAccount($0).wantsAnything }
    }

    // MARK: - Entry point

    /// Called on the main actor from RelayProcessManager.applyBatchedUpdate()
    /// with the text after the `🔔NOTIFY|` prefix.
    func handle(_ markerBody: String) {
        guard ConfigService.shared.config.enablePushNotifications else { return }

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

        // During a MacRelaySyncService catch-up round, tally instead of firing
        // individually — endCatchUpBatch() turns this into one summary. The
        // account-agnostic "summary" type itself never nests into a batch.
        if catchUpBatchDepth > 0 && type != "summary" {
            catchUpBatchCount += 1
            return
        }

        let name = author.isEmpty ? nil : NostrService.shared.profiles[author]?.bestName

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
                    "You have a new encrypted message")
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
        switch type {
        case "mention", "reply":
            NotificationCenter.default.post(name: .havenOpenMentions, object: id)
        case "reaction":
            NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
        case "repost":
            NotificationCenter.default.post(name: .havenOpenRelayNotes, object: nil)
        case "zap":
            NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
        case "dm", "giftwrap":
            NotificationCenter.default.post(name: .havenOpenDMInbox, object: nil)
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
