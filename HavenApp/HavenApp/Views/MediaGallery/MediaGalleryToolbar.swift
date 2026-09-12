import SwiftUI
import PhotosUI

// MARK: - Toolbar Extension
// Toolbar views extracted from ViewerView for the MediaGallery tab.

extension MediaGalleryView {

    // MARK: - Leading Toolbar

    /// Media type filter icons: All, Photo, Video, GIF.
    ///
    /// No Documents chip here — the row shares the bar with the sort menu, the
    /// layout toggle and upload, and this was the one worth dropping: documents
    /// are the rarest thing in the gallery and `All` still includes them. The
    /// desktop header, which has room, keeps the full set.
    @ViewBuilder
    var leadingToolbarInline: some View {
        HStack(spacing: 12) {
            let allSelected = mediaTypeFilter.count == MediaTypeFilter.allCases.count
            let photoSelected = mediaTypeFilter.contains(.photo)
            let videoSelected = mediaTypeFilter.contains(.video)
            let gifSelected = mediaTypeFilter.contains(.gif)

            IconFilterButton(
                icon: allSelected ? "circle.grid.2x2.fill" : "circle.grid.2x2",
                tooltip: "All Media",
                isSelected: allSelected,
                color: .havenPurple,
                action: selectAllMediaTypes
            )
            IconFilterButton(
                icon: photoSelected ? "photo.fill" : "photo",
                tooltip: "Photos",
                isSelected: photoSelected,
                color: .primary
            ) { toggleMediaTypeFilter(.photo) }
            IconFilterButton(
                icon: videoSelected ? "video.fill" : "video",
                tooltip: "Videos",
                isSelected: videoSelected,
                color: .primary
            ) { toggleMediaTypeFilter(.video) }
            IconFilterButton(
                icon: "GIF",
                tooltip: "GIFs",
                isSelected: gifSelected,
                color: .primary
            ) { toggleMediaTypeFilter(.gif) }
        }
    }

    // MARK: - Trailing Toolbar (inline)

    /// Grid/list layout toggle + upload button with confirmation dialog.
    @ViewBuilder
    var trailingToolbarInline: some View {
        HStack(spacing: 4) {
            sortMenu
            layoutToggleButton
            uploadButton
                .confirmationDialog("Upload Media", isPresented: $showingUploadOptions) {
                    Button("Photos") { photosPickerFilter = .images; showingPhotoPicker = true }
                    Button("Videos") { photosPickerFilter = .videos; showingPhotoPicker = true }
                    Button("Files") { showingFileImporter = true }
                    Button("Magic Paste") { handlePasteFromClipboard() }
                    Button("Cancel", role: .cancel) { }
                }
        }
    }

    // MARK: - Trailing Toolbar (compact menu)

    /// Compact menu fallback containing media type toggles, layout toggle, and upload.
    @ViewBuilder
    var trailingToolbarMenu: some View {
        Menu {
            Button {
                withAnimation { mediaLayoutMode = mediaLayoutMode == .grid ? .list : .grid }
            } label: {
                Label(
                    mediaLayoutMode == .grid ? "List View" : "Grid View",
                    systemImage: mediaLayoutMode == .grid ? "list.bullet" : "square.grid.2x2.fill"
                )
            }
            Menu {
                sortMenuItems
            } label: {
                Label("Sort by", systemImage: "arrow.up.arrow.down")
            }
            Button { showingUploadOptions = true } label: {
                Label("Upload", systemImage: "plus")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.havenPurple)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .confirmationDialog("Upload Media", isPresented: $showingUploadOptions) {
            Button("Photos") { photosPickerFilter = .images; showingPhotoPicker = true }
            Button("Videos") { photosPickerFilter = .videos; showingPhotoPicker = true }
            Button("Files") { showingFileImporter = true }
            Button("Magic Paste") { handlePasteFromClipboard() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Upload Button

    /// Plus-icon button that opens the upload options confirmation dialog.
    var uploadButton: some View {
        IconFilterButton(icon: "plus", tooltip: "Upload Options", isSelected: true, color: .havenPurple) {
            showingUploadOptions = true
        }
    }

    // MARK: - Sort

    /// The sort options, shared by the toolbar menu and the compact fallback.
    @ViewBuilder
    var sortMenuItems: some View {
        ForEach(MediaSortOption.allCases) { option in
            Button {
                withAnimation(Motion.toggle) { sortOption = option }
            } label: {
                // A checkmark on the active row rather than a separate
                // indicator: this is a one-of-many choice, not a set of toggles.
                Label(option.label, systemImage: sortOption == option ? "checkmark" : option.icon)
            }
        }
    }

    /// Toolbar entry point for sorting. Expands into the full option list.
    var sortMenu: some View {
        Menu {
            sortMenuItems
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.havenPurple)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .help("Sort by")
    }

    // MARK: - Layout Toggle

    /// Grid/list layout toggle button.
    var layoutToggleButton: some View {
        IconFilterButton(
            icon: mediaLayoutMode == .grid ? "list.bullet" : "square.grid.2x2.fill",
            tooltip: mediaLayoutMode == .grid ? "List View" : "Grid View",
            isSelected: false,
            color: .havenPurple
        ) {
            withAnimation { mediaLayoutMode = mediaLayoutMode == .grid ? .list : .grid }
        }
    }

    // MARK: - Media Type Filters

    /// Row of type filter buttons for the desktop header area.
    var mediaTypeFiltersView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 2)

                ForEach(MediaTypeFilter.allCases, id: \.self) { typeFilter in
                    FilterButton(
                        title: typeFilter.rawValue,
                        color: .havenPurple,
                        isSelected: mediaTypeFilter.contains(typeFilter)
                    ) {
                        if mediaTypeFilter.contains(typeFilter) {
                            mediaTypeFilter.remove(typeFilter)
                        } else {
                            mediaTypeFilter.insert(typeFilter)
                        }
                    }
                }
            }
        }
    }


    // MARK: - macOS Desktop Upload Menu

    /// Full upload menu used in the macOS desktop header (not the toolbar icon).
    var desktopUploadMenu: some View {
        Menu {
            Button(action: {
                photosPickerFilter = .images
                showingPhotoPicker = true
            }) {
                Label("Photos", systemImage: "photo")
            }
            Button(action: {
                photosPickerFilter = .videos
                showingPhotoPicker = true
            }) {
                Label("Videos", systemImage: "video")
            }
            Button(action: { showingFileImporter = true }) {
                Label("Files", systemImage: "folder")
            }
            Button(action: handlePasteFromClipboard) {
                Label("Magic Paste", systemImage: "wand.and.stars")
            }
            .disabled(isPastingContent)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.appSystem(size: 11, weight: .bold))
                Text("Upload")
                    .font(.appSystem(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [Color.havenPurple, Color.havenPurpleLight],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(12)
            .shadow(color: Color.havenPurple.opacity(0.3), radius: 4, x: 0, y: 2)
        }
        .menuStyle(.automatic)
    }

    // MARK: - Filter Functions

    /// Toggle a single type filter. If all are selected, narrow to just the tapped one.
    /// If only one remains selected, it cannot be deselected.
    func toggleMediaTypeFilter(_ filter: MediaTypeFilter) {
        withAnimation(Motion.toggle) {
            if mediaTypeFilter.count == MediaTypeFilter.allCases.count {
                mediaTypeFilter = [filter]
            } else if mediaTypeFilter.contains(filter) {
                if mediaTypeFilter.count > 1 {
                    mediaTypeFilter.remove(filter)
                }
            } else {
                mediaTypeFilter.insert(filter)
            }
        }
    }

    /// Select all media type filters.
    func selectAllMediaTypes() {
        withAnimation(Motion.toggle) {
            mediaTypeFilter = Set(MediaTypeFilter.allCases)
        }
    }

    /// Set the location filter, toggling back to `.all` if the same filter is tapped again.
    func selectLocationFilter(_ filter: MediaLocationFilter) {
        withAnimation(Motion.toggle) {
            if mediaLocationFilter == filter {
                mediaLocationFilter = .all
            } else {
                mediaLocationFilter = filter
            }
        }
    }
}
