import SwiftUI
import Combine

extension SearchView {
    @ViewBuilder
    var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.havenPurple)
            if pendingDirectNoteId != nil {
                Text("Looking up note...")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.appSystem(size: 32, weight: .thin))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No results found")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            // The filter, not the query, is what emptied the screen.
            if searchFilter.isActive, let snapshot = globalSnapshot,
               !(snapshot.notes.isEmpty && snapshot.profiles.isEmpty) {
                Button("Clear filter") { searchFilter = .all }
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    var resultsContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Users section
                if (resultTypeFilter == .all || resultTypeFilter == .users) && !searchResults.users.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Users")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.orderedUsers, id: \.key) { pubkey, profile in
                                userRow(pubkey: pubkey, profile: profile)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Notes section
                if (resultTypeFilter == .all || resultTypeFilter == .notes) && !searchResults.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notes")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.notes) { note in
                                FeedNoteRow(
                                   note: note,
                                   profile: nostrService.profiles[note.pubkey],
                                   rowData: FeedNoteRowData.resolve(
                                       for: note,
                                       feedService: feedService,
                                       nostrService: nostrService
                                   ),
                                   onProfile: { pubkey in
                                       showingProfile = pubkey
                                   },
                                   onMedia: { url, urls in
                                       showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                                   },
                                   showParent: false
                               )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        openNote(note)
                                    }
                            }
                        }
                        .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
                        .padding(.horizontal, 16)
                    }
                }

                // Hashtags section
                if (resultTypeFilter == .all || resultTypeFilter == .hashtags) && !searchResults.hashtags.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Hashtags")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.hashtags, id: \.self) { hashtag in
                                hashtagRow(hashtag: hashtag)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Links section
                if (resultTypeFilter == .all || resultTypeFilter == .links) && !searchResults.links.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Links")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.links, id: \.url) { link in
                                linkRow(link: link)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if searchResults.isEmpty(for: resultTypeFilter) {
                    emptyFilterState
                }
            }
            .padding(.vertical, 16)
            .tabBarBottomPadding()
        }
        .scrollDirectionTracking(feedService: feedService)
    }

    /// Shown when the query matched something, but not in the tab that is open.
    @ViewBuilder
    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            Image(systemName: resultTypeFilter.icon)
                .font(.appSystem(size: 26, weight: .thin))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No \(resultTypeFilter.label.lowercased()) matched \u{201C}\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if !searchResults.isEmpty {
                Text("Other tabs have results.")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func userRow(pubkey: String, profile: FeedProfile) -> some View {
        Button(action: { showingProfile = pubkey }) {
            HStack(spacing: 12) {
                AvatarView(url: profile.pictureURL, pubkey: pubkey, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.bestName)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(pubkey.prefix(16) + "...")
                        .font(.appSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func hashtagRow(hashtag: String) -> some View {
        Button(action: {
            // Opens the hashtag's own feed: posts tagged with it, not a word search.
            if let url = HashtagLink.url(for: hashtag) { openURL(url) }
        }) {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(hashtag)")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linkRow(link: SearchLink) -> some View {
        // A link result looks tappable (purple title, boxed row) and was inert on both
        // platforms. Rows whose URL doesn't parse stay inert rather than pretending.
        conditionalLink(url: URL(string: link.url)) {
        VStack(alignment: .leading, spacing: 4) {
            Text(link.title)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .lineLimit(1)

            Text(link.url)
                .font(.appSystem(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func conditionalLink<Content: View>(url: URL?, @ViewBuilder content: () -> Content) -> some View {
        if let url {
            Link(destination: url) { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }
}
