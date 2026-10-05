import SwiftUI

extension VaultView {

    // MARK: - Leading Toolbar

    @ViewBuilder
    var leadingToolbarInline: some View {
        HStack(spacing: 4) {
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
            IconFilterButton(icon: "person.2.fill", tooltip: "Followers", isSelected: viewMode == .followers, color: .havenPurple) {
                withAnimation(Motion.toggle) { viewMode = .followers }
            }
            .overlay(alignment: .topTrailing) {
                if hasNewFollowers {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: -5, y: 6)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .accessibilityValue(hasNewFollowers ? "New followers" : "")
        }
    }

    // MARK: - Trailing Toolbar (inline)

    // Each icon means one thing in every mode: the tray arrow in is what
    // others gave you, the arrow out is what you gave. The person icon used
    // to mean "my notes only" under Notes but "on my notes" under Likes and
    // Zaps. Whitelisted notes already show in All, and the phone has no
    // layout switch (`rowLayoutMode`).
    /// Words first; when the bar can't fit them, the selected filter drops
    /// its word, never the icons. (This used to fall back to a filter menu,
    /// which hid every option behind one button.)
    var trailingToolbarInline: some View {
        ViewThatFits(in: .horizontal) {
            trailingFilters(labelled: true)
            trailingFilters(labelled: false)
        }
    }

    @ViewBuilder
    func trailingFilters(labelled: Bool) -> some View {
        HStack(spacing: 4) {
            if viewMode == .notes {
                IconFilterButton(icon: "square.stack", tooltip: "All", isSelected: contentFilter == .all, color: .havenPurple, label: labelled ? "All" : nil) { contentFilter = .all }
                IconFilterButton(icon: "person.fill", tooltip: "Mine", isSelected: contentFilter == .mine, color: .havenPurple, label: labelled ? "Mine" : nil) { contentFilter = .mine }
                IconFilterButton(icon: "at", tooltip: "Mentions", isSelected: contentFilter == .tagged, color: .havenPurple, label: labelled ? "Mentions" : nil) { contentFilter = .tagged }
            } else if viewMode == .likes {
                IconFilterButton(icon: "tray.and.arrow.down.fill", tooltip: "Received", isSelected: likesFilter == .onMyNotes, color: .havenPurple, label: labelled ? "Received" : nil) { likesFilter = .onMyNotes }
                IconFilterButton(icon: "tray.and.arrow.up.fill", tooltip: "Given", isSelected: likesFilter == .myLikes, color: .havenPurple, label: labelled ? "Given" : nil) { likesFilter = .myLikes }
            } else if viewMode == .zaps {
                IconFilterButton(icon: "tray.and.arrow.down.fill", tooltip: "Received", isSelected: zapsFilter == .onMyNotes, color: .havenPurple, label: labelled ? "Received" : nil) { zapsFilter = .onMyNotes }
                IconFilterButton(icon: "tray.and.arrow.up.fill", tooltip: "Given", isSelected: zapsFilter == .myZaps, color: .havenPurple, label: labelled ? "Given" : nil) { zapsFilter = .myZaps }
            } else if viewMode == .followers {
                IconFilterButton(icon: "sparkles", tooltip: "New", isSelected: followersFilter == .new, color: .havenPurple, label: labelled ? "New" : nil) { followersFilter = .new }
                IconFilterButton(icon: "person.3.fill", tooltip: "All", isSelected: followersFilter == .all, color: .havenPurple, label: labelled ? "All" : nil) { followersFilter = .all }
            }
        }
        .animation(Motion.toggle, value: contentFilter)
        .animation(Motion.toggle, value: followersFilter)
        .animation(Motion.toggle, value: likesFilter)
        .animation(Motion.toggle, value: zapsFilter)
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

    var followersButton: some View {
        ModeButton(title: "Followers", icon: "person.2.fill", isSelected: viewMode == .followers, hasNotification: hasNewFollowers) {
            withAnimation(Motion.toggle) { viewMode = .followers }
        }
    }

    var modeView: some View {
        HStack(spacing: 4) {
            notesButton
            if !configService.config.zapsOnlyMode {
                likesButton
            }
            zapsButton
            followersButton
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
                    .contentShape(Rectangle())
                }
                #if os(macOS)
                // .borderlessButton flattens the label's modifiers on macOS and adds a
                // second chevron beside the drawn one.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
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
            FilterButton(title: "My Likes", icon: "heart", color: .pink, isSelected: likesFilter == .myLikes) {
                likesFilter = .myLikes
            }
        }
        .padding(4)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.8))
    }

    var followersFilterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "New", icon: "sparkles", color: .havenPurple, isSelected: followersFilter == .new) {
                followersFilter = .new
            }
            FilterButton(title: "All", icon: "person.3.fill", color: .secondary, isSelected: followersFilter == .all) {
                followersFilter = .all
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
