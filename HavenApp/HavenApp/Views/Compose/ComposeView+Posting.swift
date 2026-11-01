import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

extension ComposeView {
    private static let accountChangedMessage = "The account changed while this note was posting, so it was not sent. Your note is saved as a draft."

    func postNote() {
        // The account changed since this reply was opened (a notification
        // tap, the switcher): switch back rather than sign with the wrong key,
        // and let Post be tapped again once that account is active.
        if let npub = PostingAccount.switchTarget(postAs: postAsPicked,
                                                  active: configService.config.activeAccountNpub,
                                                  owner: configService.config.ownerNpub) {
            configService.switchActiveAccount(to: npub)
            let hex = Bech32.decode(npub)?.hexString ?? ""
            let name = nostrService.profiles[hex]?.bestName ?? AccountSwitcherIdentity.shortNpub(npub)
            let message = "This reply is for \(name). Switched back to \(name); tap Post again."
            ErrorNotificationManager.shared.show(message)
            error = message
            return
        }
        isPosting = true
        autoSaveTask?.cancel()
        autoSaveTask = nil

        // The account this note is for, locked now: the signer reads whichever
        // account is active when it signs, after the media upload, and the
        // account can change in between (see PostingAccount).
        let lockedRawNpub = configService.config.activeAccountNpub
        let lockedNpub = PostingAccount.resolve(active: lockedRawNpub, owner: configService.config.ownerNpub)
        let lockedHex = configService.activeAccountHexPubkey

        // Durably persist the current text to disk BEFORE the (potentially long) post
        // begins, so an unexpected crash during upload/mining/broadcast can't lose it.
        // The draft is cleared only once the post actually broadcasts (PendingPostManager),
        // so a cancel or crash in the pending window leaves it recoverable.
        let trimmedForDraft = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedForDraft.isEmpty || !attachments.isEmpty {
            let id = draftId ?? UUID().uuidString
            draftId = id
            DraftService.shared.saveDraftLocally(
                draftId: id,
                content: convertMentionsToNostr(content),
                replyTo: effectiveReplyTo,
                quoteTo: effectiveQuoteTo,
                taggedPubkeys: taggedPubkeys
            )
        }

        Task {
            // Request background execution time so upload + PoW mining (which can take
            // several seconds, more on slower devices or with PoW set high) isn't killed
            // mid-flight if the user backgrounds the app or locks the phone right after
            // tapping post.
            #if os(iOS)
            let bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "ComposePost", expirationHandler: nil)
            #endif
            defer {
                #if os(iOS)
                UIApplication.shared.endBackgroundTask(bgTaskId)
                #endif
            }

            // 1. Media. Each attachment began uploading when it was picked;
            // wait only for the ones still going (ComposeView+Uploads).
            if attachments.contains(where: { $0.upload != .hosted }) { isUploading = true }
            let uploadFailure = await finishUploadsForPost(lockedHex: lockedHex)
            isUploading = false
            if let uploadFailure {
                error = uploadFailure
                isPosting = false
                return
            }
            cleanupAttachmentTempFiles()

            // The text with mentions as `nostr:` references and each hosted
            // link where the author put it; links never placed go at the end.
            var finalContent = publishedText()
            let baseContent = convertMentionsToNostr(content)

            // NIP-92 descriptors, in content order. Published as `imeta` tags
            // so a reader can reserve the right box before the bytes arrive
            // and can read out what the media is.
            let mediaDescriptors = mediaDescriptors(in: finalContent)

            // Media saved on this device only: the post waits in
            // MediaPostQueue, which lays it out as it always has (text, then
            // each attachment's link in the order picked), so the placed
            // links come out of the body it keeps.
            var queuedMedia: [QueuedMediaPost.Media] = []
            var queueBody = baseContent
            let unreachableServers = note.unreachableServers
            if attachments.contains(where: { $0.upload == .savedOnDevice }) {
                for attachment in attachments {
                    let d = attachment.descriptor
                    let hostedURL = attachment.upload == .hosted ? attachment.url?.absoluteString : nil
                    if let hostedURL { queueBody = ComposerPlacement.remove(hostedURL, from: queueBody) }
                    queuedMedia.append(QueuedMediaPost.Media(
                        sha256: d.sha256, mimeType: d.mimeType, url: hostedURL,
                        pixelWidth: d.pixelWidth, pixelHeight: d.pixelHeight,
                        alt: d.alt, byteCount: d.byteCount
                    ))
                }
            }

            // 2. Build Event
            var tags: [[String]] = []
            var eventKind = 1
            let relayHint = ConfigService.shared.config.nostrURL

            if let parent = effectiveReplyTo {
                // NIP-10 tags — for reposts (kind 6), reply to the original note, not the repost
                let effectiveParentId: String
                let effectiveParentPubkey: String
                let effectiveParentTags: [[String]]
                let effectiveParentKind: Int

                if parent.kind == 6, let originalId = parent.repostedEventId {
                    effectiveParentId = originalId
                    if let original = FeedService.shared.notes.first(where: { $0.id == originalId }) {
                        effectiveParentPubkey = original.pubkey
                        effectiveParentTags = original.tags
                        effectiveParentKind = original.kind
                    } else {
                        effectiveParentPubkey = parent.pubkey
                        effectiveParentTags = parent.tags
                        effectiveParentKind = 1
                    }
                } else {
                    effectiveParentId = parent.id
                    effectiveParentPubkey = parent.pubkey
                    effectiveParentTags = parent.tags
                    effectiveParentKind = parent.kind
                }

                // NIP-10: Determine the thread root from the parent's e-tags
                let parentETags = effectiveParentTags.filter { $0.count >= 2 && $0[0] == "e" }
                let parentNonMentionETags = parentETags.filter { tag in
                    guard tag.count >= 4 else { return true }
                    return tag[3] != "mention"
                }

                let parentNonMentionATags = effectiveParentTags.filter { tag in
                    guard tag.count >= 2 && tag[0] == "a" else { return false }
                    guard tag.count >= 4 else { return true }
                    return tag[3] != "mention"
                }

                // Automatic (Logen, 2026-10-03): a note gets a kind 1 reply,
                // anything else a NIP-22 comment. No switch to explain.
                eventKind = NIP10Thread.replyKind(parentKind: effectiveParentKind)
                if eventKind == NIP10Thread.commentKind {
                    // NIP-22: on a comment, copy its root and point at it; on
                    // anything else the parent is the root (E, or A alone for
                    // addressables and replaceables).
                    tags.append(contentsOf: NIP10Thread.commentTags(
                        parentId: effectiveParentId, parentKind: effectiveParentKind,
                        parentPubkey: effectiveParentPubkey, parentTags: effectiveParentTags,
                        relayHint: relayHint
                    ))
                } else if parentNonMentionETags.isEmpty {
                    // Parent IS the root note — single e-tag with "root" marker.
                    // NIP-10: the optional 5th element is the event author's pubkey,
                    // used by the outbox model to know whose relays to fetch it from.
                    tags.append(["e", effectiveParentId, relayHint, "root", effectiveParentPubkey])
                } else {
                    // Parent is itself a reply — find the thread root
                    let threadRootId: String
                    let threadRootPubkey: String?
                    if let rootTag = parentNonMentionETags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
                        // Preferred: explicit "root" marker in parent's tags
                        threadRootId = rootTag[1]
                        threadRootPubkey = rootTag.count >= 5 ? rootTag[4] : nil
                    } else {
                        // Deprecated positional: first e-tag is the root
                        threadRootId = parentNonMentionETags[0][1]
                        threadRootPubkey = parentNonMentionETags[0].count >= 5 ? parentNonMentionETags[0][4] : nil
                    }
                    if let pk = threadRootPubkey {
                        tags.append(["e", threadRootId, relayHint, "root", pk])
                    } else {
                        tags.append(["e", threadRootId, relayHint, "root"])
                    }
                    tags.append(["e", effectiveParentId, relayHint, "reply", effectiveParentPubkey])

                    // A legacy thread under an addressable root carries its
                    // coordinate forward. a/A tags have no marker field.
                    if let rootATag = parentNonMentionATags.first(where: { $0.count >= 4 && $0[3] == "root" }) ?? parentNonMentionATags.first {
                        tags.append(["a", rootATag[1], relayHint])
                    }
                }

                // Always tag the parent author (commentReplyTags already did)
                if eventKind != NIP10Thread.commentKind {
                    tags.append(["p", effectiveParentPubkey])
                }

                // NIP-10: Accumulate p-tags from parent (thread participants), deduplicated
                var seenPubkeys = Set<String>([effectiveParentPubkey])
                for tag in effectiveParentTags where tag.count >= 2 && tag[0] == "p" {
                    let pk = tag[1]
                    if seenPubkeys.insert(pk).inserted {
                        tags.append(["p", pk])
                    }
                }
            }

            // @mention p-tags
            for mentionedPubkey in taggedPubkeys {
                // Avoid duplicating p-tags already added for reply/quote
                let alreadyTagged = tags.contains { $0.first == "p" && $0.count > 1 && $0[1] == mentionedPubkey }
                if !alreadyTagged {
                    tags.append(["p", mentionedPubkey])
                }
            }

            // Quote post: append nevent reference and q tag (NIP-18)
            var quoteSuffix: String?
            if let quoted = effectiveQuoteTo {
                quoteSuffix = "\nnostr:\(quoted.nevent)"
                finalContent += "\nnostr:\(quoted.nevent)"
                tags.append(["q", quoted.id, configService.config.publicRelayHint, quoted.pubkey])
                if !tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == quoted.pubkey }) {
                    tags.append(["p", quoted.pubkey])
                }
            }

            // NIP-18 `q` for each live stream the text embeds ("Share as a note").
            for qTag in LiveStreamShare.quoteTags(in: finalContent, relayHint: configService.config.publicRelayHint)
            where !tags.contains(where: { $0.count >= 2 && $0[0] == "q" && $0[1] == qTag[1] }) {
                tags.append(qTag)
            }

            // NIP-30: an `emoji` tag for each custom emoji the post uses.
            tags.append(contentsOf: await MainActor.run { customEmojiTags(for: baseContent) })

            // Some media is only on this device: hand the post to the queue,
            // which sends it once an outside server takes the media. Everything
            // above is kept; hashtags and imeta are rebuilt from the final URLs
            // by QueuedMediaPost.assembled(), exactly as below.
            if queuedMedia.contains(where: { $0.url == nil }) {
                let powSnap = PowPreferences.snapshot()
                let queued = QueuedMediaPost(
                    accountNpub: lockedRawNpub,
                    body: queueBody,
                    media: queuedMedia,
                    quoteSuffix: quoteSuffix,
                    baseTags: tags,
                    kind: eventKind,
                    powDifficulty: powSnap.noteEnabled ? powSnap.noteDifficulty : 0
                )
                let macHost = URL(string: configService.config.macRelayHttpsURL)?.host
                let hosts = unreachableServers.compactMap { URL(string: $0)?.host }
                await MainActor.run {
                    MediaPostQueue.shared.enqueue(queued)
                    // The queue now holds the post on disk; a draft too would
                    // offer to post it a second time.
                    if let id = self.draftId {
                        Task { await DraftService.shared.deleteDraft(id: id) }
                    }
                    ErrorNotificationManager.shared.show(
                        MediaUploadOutcomeMessage.queued(hosts: hosts, macHost: macHost),
                        icon: "clock.arrow.circlepath",
                        style: .warning
                    )
                    self.lastSavedContent = self.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    isPosting = false
                    performDismiss()
                }
                return
            }

            // NIP-24 `t` tags. Without these a note typed with #bitcoin is
            // invisible to hashtag feeds — including our own Search tab, which
            // builds its trending list from `t` tags. Read from finalContent so
            // a hashtag inside a `nostr:` reference or a media URL is excluded.
            tags.append(contentsOf: NoteTagging.hashtagTags(in: finalContent))

            // NIP-92 `imeta`, one per uploaded attachment, in content order.
            tags.append(contentsOf: NoteTagging.imetaTags(for: mediaDescriptors))

            // 3. Mine PoW + Sign — but not as an account switched to during the
            // upload: that would ask the new account's signer to sign this note.
            let accountUnchanged = await MainActor.run {
                PostingAccount.resolve(active: configService.config.activeAccountNpub, owner: configService.config.ownerNpub) == lockedNpub
            }
            guard accountUnchanged else {
                await MainActor.run {
                    ErrorNotificationManager.shared.show(Self.accountChangedMessage)
                    error = Self.accountChangedMessage
                    isPosting = false
                }
                return
            }
            let isReply = effectiveReplyTo != nil
            let powSnap = PowPreferences.snapshot()
            let powDifficulty = powSnap.noteEnabled ? powSnap.noteDifficulty : 0
            print("ComposeView: signing \(isReply ? "reply" : "post") – mode=\(configService.config.activeSigningMode()) nip46connected=\(NIP46Service.shared.isConnected) tags=\(tags.count) pow=\(powDifficulty)")
            guard let event = await nostrService.mineAndSignEventAsync(kind: eventKind, content: finalContent, tags: tags, difficulty: powDifficulty) else {
                await MainActor.run {
                    let signingMode = configService.config.activeSigningMode()
                    print("ComposeView: sign FAILED – signingMode=\(signingMode) activeNpub=\(configService.config.activeAccountNpub.prefix(20)) isReply=\(isReply)")
                    if signingMode == "nip46" {
                        error = "Remote signer failed to sign the event. Check that your bunker is connected."
                    } else {
                        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                        let isWhitelisted = !activeNpub.isEmpty && activeNpub != configService.config.ownerNpub
                        if isWhitelisted {
                            error = "No private key stored for this account. Add its nsec in Settings to post as this account."
                        } else {
                            error = "Failed to sign event. Do you have your private key set in Settings?"
                        }
                    }
                    isPosting = false
                }
                return
            }

            DispatchQueue.main.async {
                // Checked here, in the same main-queue turn that hands the note to
                // PendingPostManager (which cancels on any later switch), so no
                // switch can slip in between the check and the hand-off.
                guard PostingAccount.signedAsLocked(
                    lockedNpub: lockedNpub,
                    lockedHex: lockedHex,
                    activeNow: configService.config.activeAccountNpub,
                    owner: configService.config.ownerNpub,
                    eventPubkey: event.pubkey
                ) else {
                    print("ComposeView: account changed while posting – locked=\(lockedNpub.prefix(20)) signed=\(event.pubkey.prefix(8)); not publishing")
                    // The switch may have torn down this sheet; the banner is seen either way.
                    ErrorNotificationManager.shared.show(Self.accountChangedMessage)
                    error = Self.accountChangedMessage
                    isPosting = false
                    return
                }

                // Add to local feed immediately for preview
                let feedNote = FeedNote(
                    id: event.id,
                    pubkey: event.pubkey,
                    content: event.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                    tags: event.tags,
                    kind: event.kind
                )
                FeedService.shared.addNote(feedNote)

                // Hand to PendingPostManager — it will broadcast after countdown and then
                // delete the backing draft. We keep the draft alive until broadcast so a
                // crash/cancel during the pending window stays recoverable.
                PendingPostManager.shared.startPost(
                    event: event,
                    content: finalContent,
                    replyTo: self.effectiveReplyTo,
                    quoteTo: self.effectiveQuoteTo,
                    nostrService: self.nostrService,
                    draftId: self.draftId
                )

                // Mark content as "saved" so performDismiss won't re-save the draft
                self.lastSavedContent = self.content.trimmingCharacters(in: .whitespacesAndNewlines)

                isPosting = false
                performDismiss()
            }
        }
    }
}
