import SwiftUI

extension FeedNoteRow {
    // MARK: - Compact Layout

    /// The condensed row draws through the shared `CondensedNoteLine` so the
    /// feed, a thread's ancestors and its replies cannot drift apart again.
    @ViewBuilder
    var compactLayout: some View {
        let originalMedia = rowData.resolvedOriginal?.mediaURLs ?? []
        CondensedNoteLine(
            note: note,
            profile: rowData.displayProfile,
            displayPubkey: rowData.displayPubkey,
            depth: 0,
            style: .card,
            contentOverride: compactContentOverride,
            postedAt: postedAt,
            mediaURLs: note.mediaURLs + originalMedia,
            engagement: CondensedEngagement(
                reactions: rowData.zapsOnlyMode ? 0 : rowData.stats.reactions,
                reposts: rowData.stats.reposts
            ),
            showsTranslate: note.kind != 30023,
            onProfile: { onProfile?($0) },
            onTap: { onTapRow?() }
        )
        // Skipped when only the feed around it redrew; see `CondensedNoteLine`.
        .equatable()
    }

    /// What a condensed row shows instead of the raw note body: an article's
    /// title, or the original note behind a bare repost.
    private var compactContentOverride: String? {
        if note.kind == 6 && note.content.isEmpty, let original = rowData.resolvedOriginal {
            return original.condensedTitle ?? original.content
        }
        // A bare repost still waiting on its original said nothing at all.
        if repostedNoteIsUnavailable {
            return String(localized: "feed.note.repostUnavailable", defaultValue: "The reposted note is unavailable")
        }
        if isWaitingForRepostedNote { return String(localized: "feed.note.loadingRepost") }
        // An article's three compact lines are worth far more spent on its
        // title than on the first three lines of markdown; a poll's on its
        // question.
        return note.condensedTitle
    }

    // MARK: - Full Layout

    @ViewBuilder
    var fullLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            // [Existing body content will be extracted here]
            fullLayoutContent
        }
        .foregroundColor(Color(red: 1, green: 1, blue: 1))
        .if(!suppressCardStyling) { view in
            view
                .padding(14)
                .background(
                    ZStack {
                        Color.platformSecondaryGroupedBackground
                        Color.havenPurple.opacity(0.015)
                    }
                )
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isFocused
                                ? Color.havenPurple
                                : Color.havenPurple.opacity(ConfigService.shared.config.useOLED ? (note.isReply ? 0.40 : 0.30) : (note.isReply ? 0.15 : 0.06)),
                            lineWidth: isFocused ? 2.0 : (ConfigService.shared.config.useOLED ? 1.5 : (note.isReply ? 0.8 : 0.5))
                        )
                )
                .shadow(color: isFocused ? Color.havenPurple.opacity(0.35) : Color.clear, radius: isFocused ? 8 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                #if os(iOS)
                .hoverEffect(.lift)
                #endif
                .clipped()
        }
    }

    @ViewBuilder
    private var fullLayoutContent: some View {
        // Threading View: Parent Note Preview (shows above the current note)
        if showParent, let pId = note.parentEventId {
            if let parent = rowData.parentNote {
                NoteNavigationLink(note: parent) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            AvatarView(url: rowData.parentProfile?.pictureURL, pubkey: parent.pubkey, size: avatarSize)
                                .onTapGesture { toggleParentUserMenu() }

                            if showingParentUserMenu {
                                parentUserMenuToolbar
                            }

                            Rectangle()
                                .fill(Color.havenPurple.opacity(0.3))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(rowData.parentProfile?.bestName ?? shortKey(parent.pubkey))
                                    .font(.appSystem(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(Color(red: 0.85, green: 0.85, blue: 0.85))
                                    .lineLimit(1)
                                    .onTapGesture { onProfile?(parent.pubkey) }

                                if let pp = rowData.parentProfile, let nip05 = pp.nip05, !nip05.isEmpty {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.appCaption2)
                                        .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                                }

                                if parent.isFromNostrVault {
                                    NostrVaultBadge()
                                }

                                Spacer()

                                Text(relativeTime(parent.createdAt))
                                    .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .tracking(0.2)
                            }
                            .padding(.top, 4)

                            let parentFormatted = NostrContentFormatter.format(parent.content, mediaURLs: parent.mediaURLs)
                            if !parentFormatted.characters.isEmpty {
                                Text(parentFormatted)
                                    .font(.appSystem(size: 14, weight: .regular))
                                    .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.7))
                                    .lineLimit(2)
                            }

                            if !parent.mediaURLs.isEmpty {
                                FeedMediaView(
                                    url: parent.mediaURLs[0],
                                    maxHeight: 150,
                                    portraitMaxHeight: 200,
                                    isThumbnail: false
                                )
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
                .transition(Self.arrivalTransition)
            } else if parentFetchFailed {
                // The parent never arrived — likely not on any connected relay.
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.appSystem(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                    Text("Could not load original note")
                        .font(.appSystem(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Retry") {
                        parentFetchFailed = false
                        parentFetchStartedAt = nil
                        actions.retryMissingNote(pId)
                        scheduleParentFetchTimeout(pId)
                    }
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
                }
                .padding(.vertical, 6)
            } else {
                // Skeleton while parent is being fetched. Built from the loaded
                // preview's own fonts, spacing and two-line limit (redacted)
                // rather than fixed-size bars, so it already has the height of
                // a typical text-only parent and the swap doesn't shift the row.
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(Color.platformTertiaryGroupedBackground)
                            .frame(width: avatarSize, height: avatarSize)
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Loading name")
                                .font(.appSystem(size: 14, weight: .semibold, design: .default))
                                .lineLimit(1)
                            Spacer()
                            Text("00m")
                                .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                        }
                        .padding(.top, 4)
                        Text("Loading the original note so it can be shown above this reply")
                            .font(.appSystem(size: 14, weight: .regular))
                            .lineLimit(2)
                    }
                    .redacted(reason: .placeholder)
                    .foregroundColor(Color.platformTertiaryGroupedBackground)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading original note")
                .fixedSize(horizontal: false, vertical: true)
                .opacity(parentSkeletonShimmer ? 0.5 : 1.0)
                .animation(Motion.shimmer, value: parentSkeletonShimmer)
                .onAppear {
                    if Motion.shimmer != nil { parentSkeletonShimmer = true }
                    actions.fetchMissingNote(pId)
                    scheduleParentFetchTimeout(pId)
                }
            }
        }

        // Repost indicator
        if note.repostedBy != nil {
            HStack(spacing: 4) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.appSystem(size: 10, weight: .semibold))
                Text("\(rowData.reposterName ?? shortKey(note.repostedBy!)) reposted")
                    .font(.appSystem(size: 11, weight: .medium))
            }
            .foregroundColor(.green.opacity(0.7))
            .padding(.leading, 52)
        }

        // Main Note Content
        let displayPubkey = rowData.displayPubkey

        if layoutMode == .wide {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 6) {
                        AvatarView(url: rowData.displayProfile?.pictureURL, pubkey: displayPubkey, size: avatarSize)
                            .onTapGesture { toggleUserMenu() }
                        if showingUserMenu {
                            userMenuToolbar
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(rowData.displayProfile?.bestName ?? shortKey(displayPubkey))
                                .font(.appSystem(size: 14, weight: .semibold, design: .default))
                                .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                .lineLimit(1)
                                .onTapGesture { onProfile?(displayPubkey) }

                            if let dp = rowData.displayProfile, let nip05 = dp.nip05, !nip05.isEmpty {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.appCaption2)
                                    .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                            }

                            if bodySource.isFromNostrVault {
                                NostrVaultBadge()
                            }

                            Spacer()

                            Text(relativeTime(postedAt))
                                .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                                .tracking(0.2)

                            moreMenu
                        }

                        // Reply indicator - subtle
                        if note.isReply {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.appSystem(size: 9, weight: .semibold))
                                    .foregroundColor(Color.havenPurple.opacity(0.6))

                                if let rPubkey = note.replyToPubkey {
                                    let name = rowData.replyToName ?? shortKey(rPubkey)
                                    Text("reply to \(name)")
                                        .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.7))
                                        .tracking(0.1)
                                        .onAppear {
                                            if rowData.replyToName == nil {
                                                actions.fetchMissingProfiles([rPubkey])
                                            }
                                        }
                                }
                            }
                        }
                    }
                }

                noteBodyContent
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    if note.parentEventId != nil && rowData.parentNote != nil {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2, height: 10)
                    }

                    AvatarView(url: rowData.displayProfile?.pictureURL, pubkey: displayPubkey, size: avatarSize)
                        .onTapGesture { toggleUserMenu() }

                    if showingUserMenu {
                        userMenuToolbar
                    }

                    if isReplyToNext {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(rowData.displayProfile?.bestName ?? shortKey(displayPubkey))
                            .font(.appSystem(size: 14, weight: .semibold, design: .default))
                            .foregroundColor(Color(red: 1, green: 1, blue: 1))
                            .lineLimit(1)
                            .onTapGesture { onProfile?(displayPubkey) }

                        if let dp = rowData.displayProfile, let nip05 = dp.nip05, !nip05.isEmpty {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.appCaption2)
                                .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                        }

                        if bodySource.isFromNostrVault {
                            NostrVaultBadge()
                        }

                        Spacer()

                        Text(relativeTime(postedAt))
                            .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.2)

                        moreMenu
                    }
                    .padding(.top, 4)

                    // Reply indicator - subtle
                    if note.isReply {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.appSystem(size: 9, weight: .semibold))
                                .foregroundColor(Color.havenPurple.opacity(0.6))

                            if let rPubkey = note.replyToPubkey {
                                let name = rowData.replyToName ?? shortKey(rPubkey)
                                Text("reply to \(name)")
                                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .tracking(0.1)
                                    .onAppear {
                                        if rowData.replyToName == nil {
                                            actions.fetchMissingProfiles([rPubkey])
                                        }
                                    }
                            }
                        }
                    }

                    noteBodyContent
                }
            }
        }
    }
}
