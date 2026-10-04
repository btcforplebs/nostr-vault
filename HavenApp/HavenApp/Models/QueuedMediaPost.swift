import Foundation

/// A composed note whose media is saved on this device but has not yet reached
/// any outside Blossom server, so it cannot be published yet.
///
/// A note that embeds a `localhost` media URL is a broken image for everyone
/// else, so the composer never publishes one. It used to *cancel the post*
/// instead — one sleeping Mac vault was enough to throw away a post whose photo
/// was already safe in the phone's own Blossom. Now the post waits here, on
/// disk, and `MediaPostQueue` sends it once an outside server accepts the blob.
///
/// Everything the composer would have put in the event is kept except the
/// parts that depend on the final media URLs: those lines of content, the
/// hashtags read from the finished content, and the `imeta` tags are rebuilt by
/// `assembled()` once every attachment has a URL — the same order and the same
/// helpers `ComposeView.postNote()` uses, so a queued post and a direct post
/// come out identical.
struct QueuedMediaPost: Codable, Identifiable, Equatable {
    struct Media: Codable, Equatable {
        /// Blossom key. The blob is already in this device's relay under it.
        var sha256: String?
        var mimeType: String?
        /// nil until an outside server has accepted the blob. Media that was
        /// already hosted when composed (picked from the relay) starts non-nil.
        var url: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var alt: String?
        var byteCount: Int?
    }

    var id: String = UUID().uuidString
    var createdAt: Date = Date()
    /// npub that composed it. The signer follows the *active* account, so a
    /// post is only sent while that account is active again — otherwise it
    /// would go out under someone else's name.
    var accountNpub: String
    /// Text with mentions already converted to `nostr:` references.
    var body: String
    /// The attachments in content order.
    var media: [Media]
    /// `\nnostr:nevent…` for a quote post, appended after the media lines.
    var quoteSuffix: String?
    /// Reply, mention and quote tags. Hashtags and `imeta` are added by `assembled()`.
    var baseTags: [[String]]
    /// 1 for a note or kind 1 reply, 1111 for a NIP-22 comment. Optional so
    /// posts queued by older builds still decode; nil means 1.
    var kind: Int?
    var powDifficulty: Int = 0
    var attempts: Int = 0
    var lastAttempt: Date?

    /// Attachments still waiting for an outside server.
    var pendingMedia: [Media] { media.filter { $0.url == nil } }

    var isReady: Bool { pendingMedia.isEmpty }

    /// The event content and tags, or nil while any attachment lacks a URL.
    func assembled() -> (content: String, tags: [[String]])? {
        guard isReady else { return nil }
        var content = body
        for item in media {
            content += "\n\(item.url ?? "")"
        }
        if let quoteSuffix {
            content += quoteSuffix
        }
        var tags = baseTags
        tags.append(contentsOf: NoteTagging.hashtagTags(in: content))
        tags.append(contentsOf: NoteTagging.imetaTags(for: media.map {
            NoteTagging.MediaDescriptor(
                url: $0.url ?? "",
                mimeType: $0.mimeType,
                sha256: $0.sha256,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                alt: $0.alt,
                byteCount: $0.byteCount
            )
        }))
        return (content, tags)
    }
}

/// How a post's upload ended, in words a user can act on. Kept apart from the
/// view so the three cases cannot quietly collapse back into one message.
enum MediaUploadOutcomeMessage {
    /// No outside Blossom server is configured at all: the post can never be
    /// sent as-is, so it is not queued.
    static let noOutsideServer =
        "Your post wasn't sent: no outside media server is set up, so nobody else could see this photo. Add your Mac or another server in Settings → Media Servers, then post again."

    /// The blob never reached this device's own relay.
    static let notSavedOnDevice =
        "Your post wasn't sent: the photo couldn't be saved on this device. Try again in a moment."

    /// Saved here, waiting for an outside server. `hosts` are the servers that
    /// did not answer; `macHost` is the Mac vault's host if one is configured.
    static func queued(hosts: [String], macHost: String?) -> String {
        let waitingFor: String
        if let macHost, hosts.contains(macHost) {
            waitingFor = hosts.count == 1 ? "your Mac vault" : "your Mac vault or another media server"
        } else if hosts.count == 1, let only = hosts.first {
            waitingFor = only
        } else {
            waitingFor = "one of your media servers"
        }
        return "Saved on this device. Your post will send itself as soon as \(waitingFor) answers."
    }
}

/// Which account a note goes out as. The signer reads the account that is
/// active when it signs, and a note can wait seconds for its media to upload
/// before that — long enough for a switch (the profile-picture menu, a tapped
/// notification for another account, the Mac menu bar). So the account is
/// locked when Post is tapped and checked again once the note is signed.
enum PostingAccount {
    /// The account locked when Post was tapped.
    struct Lock {
        let npub: String
        let hex: String
    }

    /// The account a post is for: the active one, or the owner when none is set.
    static func resolve(active: String, owner: String) -> String {
        let trimmed = active.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? owner : trimmed
    }

    /// True only when the account active now is still the one locked at Post,
    /// and the signed note carries that account's key. Anything else must not
    /// be published.
    static func signedAsLocked(lockedNpub: String, lockedHex: String, activeNow: String, owner: String, eventPubkey: String) -> Bool {
        guard !lockedHex.isEmpty else { return false }
        return resolve(active: activeNow, owner: owner) == lockedNpub
            && eventPubkey.lowercased() == lockedHex.lowercased()
    }
}
