import SwiftUI

extension VaultView {

    // MARK: - Leading Toolbar

    @ViewBuilder
    var leadingToolbarInline: some View {
        HStack(spacing: 12) {
            IconFilterButton(icon: "doc.text", tooltip: "Notes", isSelected: viewMode == .notes, color: .havenPurple) {
                withAnimation(Motion.toggle) { viewMode = .notes }
            }
            if !configService.config.zapsOnlyMode {
                IconFilterButton(icon: "heart.fill", tooltip: "Likes", isSelected: viewMode == .likes, color: .havenPurple) {
                    withAnimation(Motion.toggle) { viewMode = .likes }
                    fetchMissingLikedNotes()
                }
            }
            IconFilterButton(icon: "bolt.fill", tooltip: "Zaps", isSelected: viewMode == .zaps, color: .havenPurple) {
                withAnimation(Motion.toggle) { viewMode = .zaps }
            }
        }
    }

    // MARK: - Trailing Toolbar (inline)

    @ViewBuilder
    var trailingToolbarInline: some View {
        HStack(spacing: 4) {
            IconFilterButton(
                icon: "rectangle.compress.vertical",
                tooltip: "Condensed View",
                isSelected: noteLayoutMode == .compact,
                color: .havenPurple
            ) {
                withAnimation(Motion.toggle) {
                    noteLayoutMode = noteLayoutMode == .compact ? .expanded : .compact
                }
            }

            if viewMode == .notes {
                IconFilterButton(icon: "square.stack", tooltip: "All", isSelected: contentFilter == .all, color: .havenPurple) { contentFilter = .all }
                IconFilterButton(icon: "person.fill", tooltip: "My Notes", isSelected: contentFilter == .mine, color: .havenPurple) { contentFilter = .mine }
                IconFilterButton(icon: "at", tooltip: "Tagged", isSelected: contentFilter == .tagged, color: .havenPurple) { contentFilter = .tagged }
                IconFilterButton(icon: "checkmark.seal.fill", tooltip: "Whitelisted", isSelected: contentFilter == .whitelist, color: .havenPurple) { contentFilter = .whitelist }
            } else if viewMode == .likes {
                IconFilterButton(icon: "person.fill", tooltip: "My Notes", isSelected: likesFilter == .onMyNotes, color: .havenPurple) { likesFilter = .onMyNotes }
                IconFilterButton(icon: "at", tooltip: "Tagged", isSelected: likesFilter == .onTagged, color: .havenPurple) { likesFilter = .onTagged }
                IconFilterButton(icon: "checkmark.seal.fill", tooltip: "Whitelisted", isSelected: likesFilter == .onWhitelisted, color: .havenPurple) { likesFilter = .onWhitelisted }
                IconFilterButton(icon: "heart", tooltip: "My Likes", isSelected: likesFilter == .myLikes, color: .havenPurple) { likesFilter = .myLikes }
            } else if viewMode == .zaps {
                IconFilterButton(icon: "person.fill", tooltip: "My Notes", isSelected: zapsFilter == .onMyNotes, color: .havenPurple) { zapsFilter = .onMyNotes }
                IconFilterButton(icon: "at", tooltip: "Tagged", isSelected: zapsFilter == .onTagged, color: .havenPurple) { zapsFilter = .onTagged }
                IconFilterButton(icon: "checkmark.seal.fill", tooltip: "Whitelisted", isSelected: zapsFilter == .onWhitelisted, color: .havenPurple) { zapsFilter = .onWhitelisted }
                IconFilterButton(icon: "bolt", tooltip: "My Zaps", isSelected: zapsFilter == .myZaps, color: .havenPurple) { zapsFilter = .myZaps }
            }
        }
    }

    // MARK: - Trailing Toolbar (compact menu)

    @ViewBuilder
    var trailingToolbarMenu: some View {
        Menu {
            Button {
                withAnimation(Motion.toggle) {
                    noteLayoutMode = noteLayoutMode == .compact ? .expanded : .compact
                }
            } label: {
                Label(
                    noteLayoutMode == .compact ? "Expanded View" : "Condensed View",
                    systemImage: noteLayoutMode == .compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
                )
            }
            Divider()

            if viewMode == .notes {
                Button { contentFilter = .all } label: {
                    Label("All Notes", systemImage: "square.stack")
                }
                Button { contentFilter = .mine } label: {
                    Label("My Notes", systemImage: "person.fill")
                }
                Button { contentFilter = .tagged } label: {
                    Label("Tagged", systemImage: "at")
                }
                Button { contentFilter = .whitelist } label: {
                    Label("Whitelisted", systemImage: "checkmark.seal.fill")
                }
            } else if viewMode == .likes {
                Button { likesFilter = .onMyNotes } label: {
                    Label("My Notes", systemImage: "person.fill")
                }
                Button { likesFilter = .onTagged } label: {
                    Label("Tagged", systemImage: "at")
                }
                Button { likesFilter = .onWhitelisted } label: {
                    Label("Whitelisted", systemImage: "checkmark.seal.fill")
                }
                Button { likesFilter = .myLikes } label: {
                    Label("My Likes", systemImage: "heart")
                }
            } else if viewMode == .zaps {
                Button { zapsFilter = .onMyNotes } label: {
                    Label("My Notes", systemImage: "person.fill")
                }
                Button { zapsFilter = .onTagged } label: {
                    Label("Tagged", systemImage: "at")
                }
                Button { zapsFilter = .onWhitelisted } label: {
                    Label("Whitelisted", systemImage: "checkmark.seal.fill")
                }
                Button { zapsFilter = .myZaps } label: {
                    Label("My Zaps", systemImage: "bolt")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.havenPurple)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
    }

    // MARK: - Mode / Filter Helper Views

    var notesButton: some View {
        ModeButton(title: "Notes", icon: "doc.text", isSelected: viewMode == .notes, hasNotification: hasNewNotes) {
            withAnimation(Motion.toggle) { viewMode = .notes }
        }
    }

    var likesButton: some View {
        ModeButton(title: "Likes", icon: "heart.fill", isSelected: viewMode == .likes, hasNotification: hasNewLikes) {
            withAnimation(Motion.toggle) { viewMode = .likes }
            fetchMissingLikedNotes()
        }
    }

    var zapsButton: some View {
        ModeButton(title: "Zaps", icon: "bolt.fill", isSelected: viewMode == .zaps, hasNotification: hasNewZaps) {
            withAnimation(Motion.toggle) { viewMode = .zaps }
        }
    }

    var modeView: some View {
        HStack(spacing: 4) {
            notesButton
            if !configService.config.zapsOnlyMode {
                likesButton
            }
            zapsButton
            #if os(iOS)
            // Add compact toggle on mobile
            if UIDevice.current.userInterfaceIdiom == .phone {
                compactToggleButton
            }
            #endif
        }
        .padding(4)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.platformSeparator, lineWidth: 0.8))
    }

    // `ModeButton` (labeled, filled-pill-when-selected) is the language for
    // *navigation*: which of Notes/Likes/Zaps you're looking at. This is a
    // display option, not a destination, so it used to read as a fourth mode
    // sitting in the same row — `IconFilterButton` is the icon-only language
    // the rest of the toolbar already uses for exactly that distinction (see
    // `trailingToolbarInline`'s condensed-view toggle on iOS).
    var compactToggleButton: some View {
        IconFilterButton(
            icon: noteLayoutMode == .compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
            tooltip: noteLayoutMode == .compact ? "Expanded View" : "Condensed View",
            isSelected: noteLayoutMode == .compact,
            color: .havenPurple
        ) {
            withAnimation(Motion.toggle) {
                noteLayoutMode = noteLayoutMode == .compact ? .expanded : .compact
            }
        }
    }

    // MARK: - Search

    /// The one control that opens the pane's search — `committedSearch` and
    /// `searchScope` already drove real filtering (`applySearchFilter`,
    /// `profileSearchResults`) with nothing anywhere in the UI that could set
    /// them.
    var searchToggleButton: some View {
        IconFilterButton(
            icon: isSearchActive ? "xmark" : "magnifyingglass",
            tooltip: isSearchActive ? "Close Search" : "Search",
            isSelected: isSearchActive,
            color: .havenPurple
        ) {
            withAnimation(Motion.toggle) {
                isSearchActive.toggle()
                if !isSearchActive {
                    searchQueryDraft = ""
                    committedSearch = ""
                }
            }
        }
    }

    @ViewBuilder
    var searchBar: some View {
        if isSearchActive {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Button {
                            searchScope = scope
                        } label: {
                            Label(scope.label, systemImage: scope.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: searchScope.icon)
                        Image(systemName: "chevron.down")
                            .font(.appSystem(size: 8, weight: .bold))
                    }
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize()
                .accessibilityLabel("Search scope: \(searchScope.label)")

                TextField("Search \(searchScope.label.lowercased())", text: $searchQueryDraft)
                    .textFieldStyle(.plain)
                    .font(.appSystem(size: 14))
                    .onSubmit {
                        committedSearch = searchQueryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                if !searchQueryDraft.isEmpty {
                    Button {
                        searchQueryDraft = ""
                        committedSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(red: 0.15, green: 0.15, blue: 0.2))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.8))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    var filterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "All", color: .secondary, isSelected: contentFilter == .all) {
                contentFilter = .all
            }
            FilterButton(title: "My Notes", color: .havenPurple, isSelected: contentFilter == .mine) {
                contentFilter = .mine
            }
            FilterButton(title: "Tagged", color: Color.havenVerified, isSelected: contentFilter == .tagged) {
                contentFilter = .tagged
            }
            FilterButton(title: "Whitelisted", color: Color.havenVerified.opacity(0.7), isSelected: contentFilter == .whitelist) {
                contentFilter = .whitelist
            }
        }
        .padding(4)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.8))
    }

    var likesFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "My Notes", icon: "person.fill", color: .havenPurple, isSelected: likesFilter == .onMyNotes) {
                likesFilter = .onMyNotes
            }
            FilterButton(title: "Tagged", icon: "at", color: .havenPurple, isSelected: likesFilter == .onTagged) {
                likesFilter = .onTagged
            }
            FilterButton(title: "Whitelisted", icon: "checkmark.seal.fill", color: .havenPurple, isSelected: likesFilter == .onWhitelisted) {
                likesFilter = .onWhitelisted
            }
            FilterButton(title: "My Likes", icon: "heart", color: .pink, isSelected: likesFilter == .myLikes) {
                likesFilter = .myLikes
            }
        }
        .padding(4)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.8))
    }

    var zapsFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "My Notes", icon: "person.fill", color: .havenPurple, isSelected: zapsFilter == .onMyNotes) {
                zapsFilter = .onMyNotes
            }
            FilterButton(title: "Tagged", icon: "at", color: .havenPurple, isSelected: zapsFilter == .onTagged) {
                zapsFilter = .onTagged
            }
            FilterButton(title: "Whitelisted", icon: "checkmark.seal.fill", color: .havenPurple, isSelected: zapsFilter == .onWhitelisted) {
                zapsFilter = .onWhitelisted
            }
            FilterButton(title: "My Zaps", icon: "bolt", color: .yellow, isSelected: zapsFilter == .myZaps) {
                zapsFilter = .myZaps
            }
        }
        .padding(4)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.8))
    }
}
