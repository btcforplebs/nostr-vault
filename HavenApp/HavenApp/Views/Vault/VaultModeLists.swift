import SwiftUI

extension VaultView {

    // MARK: - List Content Dispatch

    @ViewBuilder
    var listContent: some View {
        VStack(spacing: 0) {
            Group {
                if searchScope == .profiles && !committedSearch.isEmpty {
                    profileSearchResults
                } else if viewMode == .notes {
                    notesList
                } else if viewMode == .likes {
                    likesList
                } else if viewMode == .zaps {
                    zapsList
                }
            }
            .animation(.none, value: viewMode)
            .id("\(viewMode)-\(searchScope)-\(committedSearch.isEmpty)")
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    // MARK: - Notes List

    var notesList: some View {
        let isLoading = nostrService.isFetching || relayManager.isBooting || !notesHasLoadedOnce
        return Group {
            if displayNotes.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)

                        VStack(spacing: 8) {
                            Text(relayManager.isBooting ? relayManager.bootStatusMessage.isEmpty ? "Starting relay..." : relayManager.bootStatusMessage : "Loading notes...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 8) {
                        Text("No notes found")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Try changing your filter settings")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                let whitelisted = configService.whitelistedHexPubkeys
                let owner = nostrService.activeHexPubkey
                LazyVStack(spacing: 12) {
                    ForEach(displayNotes) { event in
                        let showEngagement = event.pubkey == owner || whitelisted.contains(event.pubkey)
                        #if os(iOS)
                        NavigationLink(destination: NoteDetailView(note: FeedNote(
                            id: event.id,
                            pubkey: event.pubkey,
                            content: event.content,
                            createdAt: event.createdAtDate,
                            tags: event.tags,
                            kind: event.kind
                        ))) {
                            NoteRow(
                                event: event,
                                layoutMode: noteLayoutMode,
                                reactors: showEngagement ? reactionMap[event.id] : nil,
                                latestReactionDate: showEngagement ? latestReactionDates[event.id] : nil,
                                zappers: showEngagement ? zapMap[event.id] : nil,
                                reposterPubkeys: showEngagement ? repostMap[event.id] : nil,
                                quoterPubkeys: showEngagement ? quoteMap[event.id] : nil
                            )
                        }
                        .buttonStyle(.plain)
                        #else
                        NoteRow(
                            event: event,
                            layoutMode: noteLayoutMode,
                            reactors: showEngagement ? reactionMap[event.id] : nil,
                            latestReactionDate: showEngagement ? latestReactionDates[event.id] : nil,
                            zappers: showEngagement ? zapMap[event.id] : nil,
                            reposterPubkeys: showEngagement ? repostMap[event.id] : nil,
                            quoterPubkeys: showEngagement ? quoteMap[event.id] : nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.showingNoteId = event.id
                        }
                        #endif
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Likes List

    var likesList: some View {
        let isFetching = nostrService.isFetching || relayManager.isBooting
        // Keep showing the loading view until we've either populated content
        // (likesHasLoadedOnce) or settled into a confirmed-empty state.
        let showLoading = displayLikedNotes.isEmpty
            && !likesHasLoadedOnce
            && (isFetching || !likesInitialSettled)
        return Group {
            if showLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading likes...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayLikedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: likesFilter != .myLikes ? "heart.slash" : "heart")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.red, .pink]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(likesFilter != .myLikes ? "No reactions yet" : "No liked posts")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(likesFilter != .myLikes ? "Reactions on these notes will appear here" : "Posts you've liked will appear here")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayLikedNotes) { event in
                        VStack(alignment: .leading, spacing: 0) {
                            // Show who liked this post (all incoming reaction modes)
                            if likesFilter != .myLikes, let reactors = reactionMap[event.id], !reactors.isEmpty {
                                LikedByRow(reactors: reactors, latestDate: latestReactionDates[event.id])
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 6)
                            }

                            #if os(iOS)
                            NavigationLink(destination: NoteDetailView(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            ))) {
                                NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayLikedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if event.id == displayLikedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") || id.hasPrefix("naddr1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Zaps List

    var zapsList: some View {
        // Settle-driven loading: never gate the spinner on isFetching (which is
        // ~always true here while the feed/relay fetches), or the Zaps view spins
        // forever when there are no zaps yet. Show the spinner only until the
        // initial settle completes (bounded ~6s, see updateZapsSettleState).
        let showLoading = displayZappedNotes.isEmpty
            && !zapsHasLoadedOnce
            && !zapsInitialSettled
        return Group {
            if showLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading zaps...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayZappedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: zapsFilter != .myZaps ? "bolt.slash" : "bolt")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.orange, .yellow]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(zapsFilter != .myZaps ? "No zaps yet" : "No zapped posts")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(zapsFilter != .myZaps ? "Zaps on these notes will appear here" : "Posts you've zapped will appear here")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayZappedNotes) { event in
                        VStack(alignment: .leading, spacing: 0) {
                            if zapsFilter != .myZaps, let zappers = zapMap[event.id], !zappers.isEmpty {
                                ZappedByRow(zappers: zappers)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 6)
                            }

                            #if os(iOS)
                            NavigationLink(destination: NoteDetailView(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            ))) {
                                NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayZappedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event, truncate: true, layoutMode: noteLayoutMode)
                                .padding(.horizontal, 16)
                                .onAppear {
                                    if event.id == displayZappedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "nostr" {
                        let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                            self.showingProfilePubkey = id
                            return .handled
                        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") || id.hasPrefix("naddr1") {
                            self.showingNoteId = id
                            return .handled
                        }
                    }
                    return .systemAction
                })
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Profile Search Results

    @ViewBuilder
    var profileSearchResults: some View {
        if displayProfileResults.isEmpty {
            VStack(spacing: 24) {
                Image(systemName: "person.2.slash")
                    .font(.appSystem(size: 48, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurple.opacity(0.5)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: 8) {
                    Text("No profiles found")
                        .font(.appSystem(size: 18, weight: .bold))
                        .tracking(0.2)
                    Text("Try a different search term")
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(displayProfileResults) { profile in
                    ProfileResultRow(profile: profile)
                        .onTapGesture {
                            showingProfilePubkey = profile.pubkey
                        }
                    Divider()
                        .background(Color(red: 0.2, green: 0.2, blue: 0.25))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
