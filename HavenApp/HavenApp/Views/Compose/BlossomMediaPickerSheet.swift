import SwiftUI

/// Media already on the relay, for attaching to a note. Organised exactly like
/// the Media tab — same type chips, same sort, same date headings — and it
/// reads and writes the tab's stored settings, so the two never disagree.
struct BlossomMediaPickerSheet: View {
    @Binding var blossomMedia: [MediaItem]
    @Binding var isLoading: Bool
    let onSelect: (MediaItem) -> Void
    let onAppearLoad: () -> Void
    @Environment(\.dismiss) var dismiss

    @AppStorage(MediaTypeFilter.storageKey) private var typeFilterRaw: String =
        MediaTypeFilter.rawSelection(Set(MediaTypeFilter.allCases))
    @AppStorage(MediaSortOption.storageKey) private var sortOptionRaw: String = MediaSortOption.newestFirst.rawValue

    private var typeFilter: Set<MediaTypeFilter> { MediaTypeFilter.selection(from: typeFilterRaw) }
    private var sortOption: MediaSortOption { MediaSortOption(rawValue: sortOptionRaw) ?? .newestFirst }

    #if os(macOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    #else
    /// Width of the grid, which on iPad is the form sheet's width rather than
    /// the window's. Zero until measured, which reads as the phone count.
    @State private var gridWidth: CGFloat = 0
    private var columns: [GridItem] {
        AdaptiveLayout.columns(width: gridWidth, ideal: 150, spacing: 6, minimum: 3, maximum: 6)
    }
    #endif

    /// Every item here is on the relay by construction, so "On relay first"
    /// reduces to its date tiebreak.
    private var filteredMedia: [MediaItem] {
        let selection = typeFilter
        return sortOption.sorted(blossomMedia.filter { selection.contains(MediaTypeFilter.category(of: $0)) }) { _ in true }
    }

    private var sections: [MediaDateSection] {
        guard sortOption.groupsByDate else {
            return [MediaDateSection(id: "all", title: "", items: filteredMedia)]
        }
        return MediaDateSection.sections(for: filteredMedia)
    }

    /// Same toggle rules as the Media tab: from "all", a tap isolates that
    /// type; the last selected type cannot be switched off.
    private func toggle(_ filter: MediaTypeFilter) {
        var selection = typeFilter
        if selection.count == MediaTypeFilter.allCases.count {
            selection = [filter]
        } else if selection.contains(filter) {
            if selection.count > 1 { selection.remove(filter) }
        } else {
            selection.insert(filter)
        }
        withAnimation(Motion.toggle) { typeFilterRaw = MediaTypeFilter.rawSelection(selection) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Loading media...")
                            .font(.appSystem(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredMedia.isEmpty && !blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.macro")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(Color.havenPurple.opacity(0.6))
                        Text("No media matches these filters")
                            .font(.appSystem(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if blossomMedia.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.macro")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(Color.havenPurple.opacity(0.6))
                        Text("No media on Blossom")
                            .font(.appSystem(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.items) { item in
                                        BlossomPickerGridItem(item: item)
                                            .onTapGesture { onSelect(item) }
                                    }
                                } header: {
                                    sectionHeader(section.title)
                                }
                            }
                        }
                        #if os(iOS)
                        .measureWidth { gridWidth = $0 }
                        #endif
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    typeFilterButtons
                }
                ToolbarItem(placement: .primaryAction) {
                    sortMenu
                }
            }
        }
        .onAppear { onAppearLoad() }
    }

    /// The Media tab's type row: All, Photo, Video, GIF.
    private var typeFilterButtons: some View {
        HStack(spacing: 12) {
            let allSelected = typeFilter.count == MediaTypeFilter.allCases.count
            let photoSelected = typeFilter.contains(.photo)
            let videoSelected = typeFilter.contains(.video)
            let gifSelected = typeFilter.contains(.gif)

            IconFilterButton(
                icon: allSelected ? "circle.grid.2x2.fill" : "circle.grid.2x2",
                tooltip: "All Media",
                isSelected: allSelected,
                color: .havenPurple
            ) {
                withAnimation(Motion.toggle) {
                    typeFilterRaw = MediaTypeFilter.rawSelection(Set(MediaTypeFilter.allCases))
                }
            }
            IconFilterButton(
                icon: photoSelected ? "photo.fill" : "photo",
                tooltip: "Photos",
                isSelected: photoSelected,
                color: .primary
            ) { toggle(.photo) }
            IconFilterButton(
                icon: videoSelected ? "video.fill" : "video",
                tooltip: "Videos",
                isSelected: videoSelected,
                color: .primary
            ) { toggle(.video) }
            IconFilterButton(
                icon: "GIF",
                tooltip: "GIFs",
                isSelected: gifSelected,
                color: .primary
            ) { toggle(.gif) }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(MediaSortOption.allCases) { option in
                Button {
                    withAnimation(Motion.toggle) { sortOptionRaw = option.rawValue }
                } label: {
                    Label(option.label, systemImage: sortOption == option ? "checkmark" : option.icon)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.havenPurple)
        }
        .accessibilityLabel("Sort")
        #if os(macOS)
        // A default Menu drops the label's purple and weight on the Mac.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Sort")
        #endif
    }

    /// Pinned date heading, styled like the Media tab's. Nothing for the
    /// untitled single section a non-date sort produces.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if !title.isEmpty {
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
}

private struct BlossomPickerGridItem: View {
    let item: MediaItem

    var body: some View {
        Color.clear
            .aspectRatio(1.0, contentMode: .fit)
            .overlay(
                Group {
                    if item.type == .video {
                        VideoThumbnailView(url: item.url, mimeType: item.mimeType)
                    } else if item.type == .audio {
                        ZStack {
                            Color(red: 0.1, green: 0.1, blue: 0.14)
                            Image(systemName: "waveform")
                                .font(.appSystem(size: 28))
                                .foregroundColor(.havenPurple)
                        }
                    } else if item.isAnimatedGIF {
                        AnimatedThumbnail(url: item.url)
                    } else {
                        RetryableAsyncImage(url: item.url, contentMode: .fill, targetSize: CGSize(width: 200, height: 200))
                    }
                }
            )
            .background(Color.black.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
