import SwiftUI

extension FeedView {
    var mediaGridView: some View {
        Group {
            let filteredNotes = feedService.filteredMediaNotes

            if filteredNotes.isEmpty && !feedService.isLoadingFeed {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.appSystem(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(localized: "feed.media.empty.title"))
                        .font(.appSystem(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(feedService.mediaFeedMode == .following ? String(localized: "feed.media.empty.following") : String(localized: "feed.media.empty.global"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 400)
            } else {
                // Three across on a phone; the iPad's wider pane gets more
                // tiles instead of three blown-up ones.
                let columns = AdaptiveLayout.columns(width: mediaGridWidth, ideal: 180,
                                                     spacing: 2, minimum: 3, maximum: 7)

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(filteredNotes) { note in
                        if let firstMediaURL = note.mediaURLs.first {
                            gridCell(for: note, url: firstMediaURL)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedGridMediaNoteId = note.id
                                    gridMediaViewer = GridMediaViewerRoute(notes: filteredNotes)
                                }
                                .onLongPressGesture(minimumDuration: 0.5) {
                                    showingNoteId = note.id
                                }
                        }
                    }
                }
                .measureWidth { mediaGridWidth = $0 }
                .padding(.horizontal, 2)
                
                // Show "Show earlier" button for pagination
                if !filteredNotes.isEmpty {
                    Button {
                        feedService.loadMore()
                    } label: {
                        HStack(spacing: 8) {
                            if feedService.isLoadingFeed {
                                ProgressView().controlSize(.small).tint(Color.havenPurple)
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.appSystem(size: 12, weight: .semibold))
                            }
                            Text(feedService.isLoadingFeed ? String(localized: "feed.loading.indicator") : String(localized: "feed.media.showEarlier"))
                                .font(.appSystem(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.platformSeparator, lineWidth: 1))
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(feedService.isLoadingFeed)
                }
                
                Color.clear.frame(height: 80) // Space for floating button
            }
        }
    }

    private func gridCell(for note: FeedNote, url: URL) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                FeedMediaView(url: url, isThumbnail: true)
                    .meshMediaNote(author: note.pubkey, tags: note.tags)
                    .frame(width: geo.size.width, height: geo.size.width)
                    .clipped()

                // Indicators overlay
                HStack(spacing: 4) {
                    if note.mediaURLs.count > 1 {
                        Image(systemName: "square.fill.on.square.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else if let extensionType = FeedMediaType.fromExtension(url), extensionType == .video {
                        Image(systemName: "play.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fill)
    }
}
