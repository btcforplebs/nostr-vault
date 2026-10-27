import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension FeedNoteRow {
    /// The event whose body this row draws: for an empty-content repost that is
    /// the reposted original, everywhere else the note itself.
    ///
    /// The quote cards have to come from the same event as the text. Reading
    /// them off the kind 6 wrapper — whose content is empty, so it quotes
    /// nothing — made a repost of a quote-post show the reposted text with its
    /// reference stripped and no card underneath.
    var bodySource: FeedNote {
        if note.kind == 6 && note.content.isEmpty, note.repostedEventId != nil,
           let original = rowData.resolvedOriginal {
            return original
        }
        return note
    }

    /// When the note this row shows was written. A repost shows its original's
    /// time, not the moment it was reposted.
    var postedAt: Date {
        bodySource.originalCreatedAt ?? bodySource.createdAt
    }

    /// Who a zap on this row pays: the author of the note a repost carries,
    /// never the person who reposted it.
    var zapRecipient: String {
        FeedService.shared.originalNote(for: note).pubkey
    }

    /// True while an empty-content repost is waiting for the note it reposted.
    var isWaitingForRepostedNote: Bool {
        note.kind == 6 && note.content.isEmpty && note.repostedEventId != nil
            && rowData.resolvedOriginal == nil
    }

    /// An empty-content repost whose original no relay returned (deleted, or
    /// never reached anywhere we ask). Without this it said "Loading" forever.
    var repostedNoteIsUnavailable: Bool {
        guard isWaitingForRepostedNote, let refId = note.repostedEventId else { return false }
        return FeedService.shared.unavailableNoteIds.contains(refId)
    }

    @ViewBuilder
    var noteBodyContent: some View {
        // Content Body — for empty-content reposts this is the reposted note.
        if repostedNoteIsUnavailable {
            Text(String(localized: "feed.note.repostUnavailable", defaultValue: "The reposted note is unavailable"))
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        } else if isWaitingForRepostedNote {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "feed.note.loadingRepost"))
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } else if bodySource.kind == 30023 {
            // Long-form arrives in the notes feed alongside kinds 1 and 6. Its
            // title lives in a tag and its body is markdown, so the plain-text
            // path below drew the whole article raw and untitled.
            ArticleInlineBody(note: bodySource, isFocused: isFocused)
        } else if bodySource.kind == FeedNote.highlightKind {
            // The plain path drew the passage as if the highlighter wrote it,
            // with nothing saying where it came from.
            HighlightInlineBody(note: bodySource, isFocused: isFocused)
        } else if let poll = bodySource.poll {
            // A NIP-88 poll's question is its content and its options are
            // tags, so the plain-text path drew the question with nothing
            // to vote on. The question is drawn here, not by the card, so a
            // picture or link in it goes through the same media path as any
            // note — drawn as a plain string it showed only the bare URLs
            // (Logen, 2026-10-07).
            let attachments = bodySource.mediaURLs + LinkCards.shown(bodySource.linkURLs)
            let question = NostrContentFormatter.format(bodySource.content, mediaURLs: attachments)
            VStack(alignment: .leading, spacing: 8) {
                if !String(question.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(question)
                        .font(.appSystem(size: isFocused ? 19 : 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !bodySource.mediaURLs.isEmpty {
                    feedMediaCarousel(urls: bodySource.mediaURLs)
                }
                ForEach(LinkCards.shown(bodySource.linkURLs), id: \.self) { url in
                    LinkPreviewCard(url: url)
                }
                PollCardView(poll: poll, isFocused: isFocused, showsQuestion: false)
            }
            .padding(.top, 4)
        } else {
            let invoices = NoteInvoices.find(in: bodySource.content)
            // Each link's card sits where the link was written, between the
            // text before and after it.
            let segments = NoteURLs.segments(bodySource.content, cards: LinkCards.shown(bodySource.linkURLs))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let piece):
                        Text(NostrContentFormatter.format(piece, mediaURLs: bodySource.mediaURLs, invoices: invoices))
                            .font(.appSystem(size: 17, weight: .regular, design: .default))
                            .foregroundColor(Color(red: 1, green: 1, blue: 1))
                            .lineSpacing(2)
                            .lineLimit(nil)
                            .textSelection(.enabled)
                    case .link(let url):
                        LinkPreviewCard(url: url)
                    }
                }
                NoteTranslateButton(noteID: bodySource.id, content: bodySource.content, kind: bodySource.kind)
            }
            .padding(.top, 4)

            // Media previews
            if !bodySource.mediaURLs.isEmpty {
                feedMediaCarousel(urls: bodySource.mediaURLs)
                    .padding(.top, 4)
            }

            // Lightning invoices — cut from the text, drawn as pay cards.
            ForEach(invoices, id: \.invoice) { match in
                LightningInvoiceCard(match: match)
                    .padding(.top, 4)
            }
        }

        // Quoted Notes
        if !bodySource.quotedEventIds.isEmpty {
            VStack(spacing: 8) {
                ForEach(bodySource.quotedEventIds, id: \.self) { quoteId in
                    if let quotedNote = actions.findNote(quoteId) {
                        // QuotedNoteView decides what a tap does: streams play,
                        // a quote of someone you blocked does nothing.
                        QuotedNoteView(note: quotedNote, opensThread: true)
                            .transition(Self.arrivalTransition)
                    } else if quoteFetchFailed.contains(quoteId) {
                        Text("Quoted note unavailable")
                            .font(.appSystem(size: 12, weight: .regular))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        QuotedNoteSkeleton()
                            .onAppear {
                                actions.fetchMissingNote(quoteId)
                                scheduleQuoteFetchTimeout(quoteId)
                            }
                    }
                }
            }
            .padding(.top, 4)
        }


        // Actions row - minimal and clean. Where the caller fetched the
        // numbers (profiles), each button carries its own count.
        let engagement = rowData.engagement
        HStack(spacing: engagement == nil ? 12 : 8) {
            actionButton(icon: "message", count: engagement?.replies, countLabel: "replies", action: { onReply?() })
                .accessibilityLabel("Reply")

            actionButton(
                icon: "arrow.2.squarepath",
                color: rowData.isReposted ? .green : .secondary,
                count: engagement?.reposts, countLabel: "reposts",
                action: {
                    actions.repostNote(note)
                    Motion.firePulse($repostPulse)
                }
            )
            .accessibilityLabel(rowData.isReposted ? "Reposted" : "Repost")
            .scaleEffect(repostPulse ? Motion.pulseScale : 1.0)
            .animation(Motion.pop, value: repostPulse)

            actionButton(icon: "quote.closing", count: engagement?.quotes, countLabel: "quotes", action: { onQuote?() })
                .accessibilityLabel("Quote")

            if !rowData.zapsOnlyMode {
                reactionButton
                    .popover(isPresented: $showingEmojiPicker) {
                        EmojiPickerView { emoji in
                            pickReaction(emoji)
                        }
                        #if os(iOS)
                        .presentationDetents([.height(520)])
                        #endif
                    }
                    #if os(macOS)
                    .popover(isPresented: $showingTapbackPopover, arrowEdge: .top) {
                        ReactionTapbackBar(
                            options: ReactionTapback.options(defaultContent: ConfigService.shared.config.defaultReactionEmoji),
                            current: rowData.isLiked ? reactionDisplayEmoji(rowData.myReaction ?? "+") : nil,
                            highlighted: nil
                        ) { index in
                            showingTapbackPopover = false
                            let options = ReactionTapback.options(defaultContent: ConfigService.shared.config.defaultReactionEmoji)
                            if index < options.count {
                                pickReaction(options[index])
                            } else {
                                // One popover has to finish closing before the next opens.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    showingEmojiPicker = true
                                }
                            }
                        }
                        .padding(6)
                    }
                    #endif
            }

            if rowData.hasNWC && PostButtons.showsZap(postButtons) {
                let lud16 = actions.getLightningAddress(zapRecipient)
                let isZapped = rowData.zapAmount != nil
                let hasLightning = lud16 != nil
                HStack(spacing: 4) {
                    Image(systemName: isZapped ? "bolt.fill" : "bolt")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(isZapped ? .orange : (hasLightning ? .secondary : .secondary.opacity(0.35)))
                    countText(engagement?.zapSats)
                }
                    .padding(.horizontal, (engagement?.zapSats ?? 0) > 0 ? 10 : 0)
                    .frame(minWidth: 32, minHeight: 32, maxHeight: 32)
                    .background(isZapped ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .zapFlightTarget(zapBoltAnchor)
                    .overlay { ZapBurstView(isAnimating: $showLightning) }
                    .scaleEffect(zapPulse ? Motion.pulseScale : 1.0)
                    .animation(Motion.pop, value: zapPulse)
                    .contentShape(Capsule())
                    .accessibilityLabel(isZapped ? "Zapped" : "Zap")
                    .accessibilityValue(countLabel(engagement?.zapSats, "sats zapped"))
                    .accessibilityHint(hasLightning ? "Tap to send sats" : "No lightning address")
                    .onLongPressGesture {
                        if hasLightning {
                            #if os(iOS)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                            zapSheetContext = ZapSheetContext(defaultAmount: rowData.defaultZapAmount / 1000)
                        }
                    }
                    .onTapGesture {
                        if let lud16 = lud16 {
                            Task {
                                let sent = await actions.zapNote(note, lud16, nil)
                                if sent { Motion.firePulse($zapPulse) }
                            }
                            // Sats fly from your avatar to this button and
                            // burst on landing; with nowhere to fly from (or
                            // Reduce Motion) the burst plays on its own.
                            if !ZapFlightCoordinator.shared.launch(to: zapBoltAnchor, onArrive: { showLightning = true }) {
                                showLightning = true
                            }
                        } else {
                            noLightningAddressAlert = true
                        }
                    }
            } else if let sats = engagement?.zapSats, sats > 0 {
                // No wallet to zap from, but the sats others sent still show.
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.orange.opacity(0.85))
                    countText(sats)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(countLabel(sats, "sats zapped"))
            }

            actionButton(icon: "antenna.radiowaves.left.and.right", action: { showingBroadcastSheet = true })
                .accessibilityLabel("Event Info")

            Spacer()
        }
        .padding(.top, 4)
    }

    /// A button's count, compact ("2.1k", "64+"), or nothing for zero.
    @ViewBuilder
    func countText(_ value: Int?) -> some View {
        if let value, value > 0, let engagement = rowData.engagement {
            Text(engagement.display(value))
                .font(.appSystem(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// The count as VoiceOver reads it: "at least 64 likes" when it is a lower bound.
    func countLabel(_ value: Int?, _ noun: String) -> String {
        guard let value, value > 0, let engagement = rowData.engagement else { return "" }
        let lowerBound = engagement.isLowerBound && value >= PostEngagement.lowerBoundFrom
        return lowerBound ? "at least \(value) \(noun)" : "\(value) \(noun)"
    }
}
