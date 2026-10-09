import SwiftUI

extension MediaGalleryView {

    // MARK: - Media Content Dispatch

    @ViewBuilder
    var mediaContent: some View {
        let items = displayMedia
        let isLoading = blossomCache.isScanning || nostrService.isFetching || !mediaHasLoadedOnce

        if items.isEmpty && isLoading {
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 8) {
                        Text("Loading media...")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.3)
                        Text("Scanning for uploads")
                            .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                            .tracking(0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.platformWindowBackground)
        } else if items.isEmpty {
            VStack(spacing: 24) {
                Image(systemName: "photo.on.rectangle")
                    .font(.appSystem(size: 48, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 8) {
                    Text("No media found")
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.2)

                    // Only when a filter is what hid it all; with no media
                    // at all there is no setting to change (as on Android).
                    if mediaTotalCount > 0 {
                        Text("Try changing your filter settings")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.platformWindowBackground)
        } else {
            mediaGrid
        }
    }

    // MARK: - Sections

    /// The list broken into dated runs. Under a non-date sort this collapses to
    /// a single untitled section, so the same rendering path serves both.
    static func sections(for items: [MediaItem], sortOption: MediaSortOption) -> [MediaDateSection] {
        guard sortOption.groupsByDate else {
            return [MediaDateSection(id: "all", title: "", items: items)]
        }
        return MediaDateSection.sections(for: items)
    }

    /// Pinned heading for a dated run. Renders nothing for the untitled
    /// single-section case, so no empty bar appears under a non-date sort.
    @ViewBuilder
    func mediaSectionHeader(_ title: String) -> some View {
        if title.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                Text(title)
                    .font(.appSystem(size: 13, weight: .bold, design: .rounded))
                    .tracking(0.3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Media Grid / List Layout

    var mediaGrid: some View {
        Group {
            if mediaLayoutMode == .grid {
                #if os(macOS)
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
                #else
                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
                #endif

                LazyVGrid(columns: columns, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(mediaSections) { section in
                        Section {
                            ForEach(section.items) { item in
                                MediaGridItem(
                                    item: item,
                                    onDeleteFromMirrors: { deleteMediaFromMirrors(item: $0) },
                                    onDeleteEverywhere: { deleteMediaEverywhere(item: $0) },
                                    onMirrorComplete: { loadLocalMedia(force: true) }
                                ) {
                                    withAnimation(Motion.pick) { selectedMedia = item }
                                }
                                .onAppear {
                                    if item.id == displayMedia.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            }
                        } header: {
                            mediaSectionHeader(section.title)
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(mediaSections) { section in
                        Section {
                            ForEach(section.items) { item in
                                MediaListItem(
                                    item: item,
                                    onDeleteFromMirrors: { deleteMediaFromMirrors(item: $0) },
                                    onDeleteEverywhere: { deleteMediaEverywhere(item: $0) },
                                    onMirrorComplete: { loadLocalMedia(force: true) }
                                ) {
                                    withAnimation(Motion.pick) { selectedMedia = item }
                                }
                                .onAppear {
                                    if item.id == displayMedia.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            }
                        } header: {
                            mediaSectionHeader(section.title)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }
}
