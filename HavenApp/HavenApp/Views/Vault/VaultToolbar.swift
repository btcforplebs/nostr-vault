import SwiftUI

extension VaultView {

    // MARK: - Leading Toolbar

    @ViewBuilder
    var leadingToolbarInline: some View {
        if vaultTabHostsMedia {
            VaultModePill(mode: vaultMode, zapsOnly: configService.config.zapsOnlyMode)
        } else {
            leadingIconRow
        }
    }

    /// The Vault tab's menu entry for what this view is showing.
    var vaultMode: VaultMode {
        switch viewMode {
        case .activity: return .activity
        case .likes: return .likes
        case .zaps: return .zaps
        case .followers: return .followers
        default:
            switch noteScope {
            case .notes: return .notes
            case .articles: return .articles
            case .highlights: return .highlights
            }
        }
    }

    /// Your Vault's cards point at this half's pill and Vault button unless
    /// the Vault tab is showing Media, whose pill and button take them.
    var showsVaultTutorialAnchors: Bool {
        !(vaultTabHostsMedia && vaultShowsMedia)
    }

    /// Articles and Highlights are a few rows among many notes. The list's
    /// end is always on screen, so loading older pages on sight would walk
    /// the whole relay; they page by button instead.
    var sparseNotesScope: Bool {
        vaultTabHostsMedia && viewMode == .notes && noteScope != .notes && !isSearchActive
    }

    /// Gone once a page comes back empty: there is nothing older to load.
    @ViewBuilder
    var loadOlderButton: some View {
        if !noOlderPages.contains(noteScope) {
            loadOlderButtonBody
        }
    }

    private var loadOlderButtonBody: some View {
        Button { loadOlderInScope() } label: {
            HStack(spacing: 6) {
                if isLoadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Text("Load older")
            }
            .font(.appSystem(size: 14, weight: .semibold))
            .foregroundColor(.havenPurple)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Color.havenPurple.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(isLoadingOlder)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// Modes with something new, for the dots the icon row used to carry.
    var vaultModesWithNews: Set<VaultMode> {
        var modes = Set<VaultMode>()
        if hasNewNotes { modes.insert(.notes) }
        if hasNewLikes { modes.insert(.likes) }
        if hasNewZaps { modes.insert(.zaps) }
        if hasNewFollowers { modes.insert(.followers) }
        return modes
    }

    @ViewBuilder
    var leadingIconRow: some View {
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
    /// The right pill: Messages, a line, then this mode's filters as bare
    /// icons, then search at the right end. A filter tap says what it picked
    /// in the note under the bar.
    /// On a narrow phone (an SE in Articles has ✉️ and five filters) the
    /// buttons narrow before the bar would fold the pill into "•••".
    var trailingToolbarInline: some View {
        ViewThatFits(in: .horizontal) {
            trailingPill(buttonWidth: 36, spacing: 4)
            trailingPill(buttonWidth: 30, spacing: 0)
            trailingPill(buttonWidth: 26, spacing: 0)
        }
    }

    private func trailingPill(buttonWidth: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            VaultMessagesButton()
            if viewMode != .media {
                Divider().frame(height: 20).padding(.horizontal, 2)
                trailingFilters(spacing: spacing)
            }
            Divider().frame(height: 20).padding(.horizontal, 2)
            searchToggleButton
        }
        .environment(\.filterButtonWidth, buttonWidth)
    }

    @ViewBuilder
    func trailingFilters(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            switch viewMode {
            case .activity:
                filterButton(.activity(.all), "square.stack", "All", activityFilter == .all) { activityFilter = .all }
                filterButton(.activity(.mentions), "at", "Mentions", activityFilter == .mentions) { activityFilter = .mentions }
            case .notes:
                filterButton(.notes(.all), "square.stack", "All", contentFilter == .all) { contentFilter = .all }
                filterButton(.notes(.mine), "person.fill", "Mine", contentFilter == .mine) { contentFilter = .mine }
                filterButton(.notes(.tagged), "at", "Mentions", contentFilter == .tagged) { contentFilter = .tagged }
                filterButton(.notes(.outside), "person.crop.circle.badge.questionmark", "Replies from outside your network", contentFilter == .outside) { contentFilter = .outside }
                if vaultTabHostsMedia && noteScope == .articles {
                    filterButton(.recipes, "fork.knife", "Recipes only", recipesOnly) { recipesOnly.toggle() }
                }
            case .likes:
                filterButton(.likes(.onMyNotes), "tray.and.arrow.down.fill", "Received", likesFilter == .onMyNotes) { likesFilter = .onMyNotes }
                filterButton(.likes(.myLikes), "tray.and.arrow.up.fill", "Given", likesFilter == .myLikes) { likesFilter = .myLikes }
            case .zaps:
                filterButton(.zaps(.onMyNotes), "tray.and.arrow.down.fill", "Received", zapsFilter == .onMyNotes) { zapsFilter = .onMyNotes }
                filterButton(.zaps(.myZaps), "tray.and.arrow.up.fill", "Given", zapsFilter == .myZaps) { zapsFilter = .myZaps }
            case .followers:
                filterButton(.followers(.new), "sparkles", "New", followersFilter == .new) { followersFilter = .new }
                filterButton(.followers(.all), "person.3.fill", "All", followersFilter == .all) { followersFilter = .all }
            case .media:
                EmptyView()
            }
        }
        .animation(Motion.toggle, value: activityFilter)
        .animation(Motion.toggle, value: contentFilter)
        .animation(Motion.toggle, value: recipesOnly)
        .animation(Motion.toggle, value: followersFilter)
        .animation(Motion.toggle, value: likesFilter)
        .animation(Motion.toggle, value: zapsFilter)
    }

    private func filterButton(_ choice: VaultFilterChoice, _ icon: String, _ tooltip: String,
                              _ isSelected: Bool, _ pick: @escaping () -> Void) -> some View {
        IconFilterButton(icon: icon, tooltip: tooltip, isSelected: isSelected, color: .havenPurple) {
            pick()
            noteFilterTap(choice, changed: !isSelected || choice == .recipes)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The Mac header's labelled filters: the pick, then the same note.
    func tapFilter(_ choice: VaultFilterChoice, _ isSelected: Bool, _ pick: () -> Void) {
        pick()
        noteFilterTap(choice, changed: !isSelected)
    }

    // MARK: - Filter note

    /// A filter tap's note: what it shows and that it's on, straight away.
    /// A list rebuilt off the main thread adds its count when it lands, if
    /// the note is still up.
    func noteFilterTap(_ choice: VaultFilterChoice, changed: Bool) {
        if choice == .recipes && !recipesOnly {
            pendingFilterNote = nil
            filterNote.show(.off(choice.name(scope: noteScope), icon: choice.icon))
            return
        }
        guard changed, choice.waitsForList else {
            pendingFilterNote = nil
            filterNote.show(filterNoteText(choice))
            return
        }
        pendingFilterNote = choice
        // A rebuild already running for the old pick must not land as this
        // one's count; onChange schedules the new rebuild.
        updateGeneration += 1
        filterNote.show(FilterNote(icon: choice.icon, title: choice.name(scope: noteScope), setting: "on"))
    }

    /// A rebuilt list landed: the note, if still showing, gets its count.
    /// One that has faded stays gone.
    func filterListLanded() {
        guard let choice = pendingFilterNote else { return }
        pendingFilterNote = nil
        filterNote.update(filterNoteText(choice))
    }

    /// What the filter shows, that it's on, then how many: "Mentions · on ·
    /// 18", "none yet" rather than a 0. A list that stopped at its page size
    /// says so with a "+".
    func filterNoteText(_ choice: VaultFilterChoice) -> FilterNote {
        let (count, capped) = filterCount(choice)
        let tally = count == 0 ? "none yet" : "\(count.formatted())\(capped ? "+" : "")"
        return FilterNote(icon: choice.icon, title: choice.name(scope: noteScope), setting: "on", count: tally)
    }

    private func filterCount(_ choice: VaultFilterChoice) -> (Int, Bool) {
        switch choice {
        case .activity:
            return (displayActivity.count, displayActivity.count >= maxDisplayedItems)
        case .notes, .recipes:
            return (displayNotes.count, displayNotes.count >= maxDisplayedItems)
        case .likes:
            return (displayLikedNotes.count, displayLikedNotes.count >= maxDisplayedItems)
        case .zaps:
            return (displayZappedNotes.count, displayZappedNotes.count >= maxDisplayedItems)
        case .followers(let filter):
            return (followerSnapshot?.entries(for: filter).count ?? 0, false)
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
            pendingFilterNote = nil
            filterNote.show(noteLayoutMode == .compact
                ? FilterNote(icon: "rectangle.compress.vertical", title: "Condensed view", setting: "on")
                : .off("Condensed view", icon: "rectangle.compress.vertical"))
        }
    }

    // MARK: - Search

    /// The magnifying glass at the right end of the Vault's toolbar. It opens
    /// `VaultSearchBar`, which grows out of this spot; on the Mac it sits in
    /// the header and the bar opens under it. It stays a magnifying glass
    /// while the bar is open — the bar's own ✕ is the one way to close, so
    /// the fold back into the icon always plays — and pressed again (or ⌘F)
    /// it puts the cursor back in the field.
    var searchToggleButton: some View {
        IconFilterButton(
            icon: "magnifyingglass",
            tooltip: "Search your Vault",
            isSelected: isSearchActive,
            color: .havenPurple
        ) {
            if isSearchActive { searchFocusRequest &+= 1 } else { openVaultSearch() }
        }
        #if os(macOS)
        // iPad keeps ⌘F for the Search tab (ContentView).
        .keyboardShortcut("f", modifiers: .command)
        #endif
        .accessibilityLabel("Search your Vault")
    }

    func openVaultSearch() {
        pendingFilterNote = nil
        filterNote.hide()
        // No animation here: the toolbar steps aside at once, and the bar's
        // own expand out of the icon is the one motion. Animated, the
        // toolbar slid up while the bar grew under it.
        isSearchActive = true
    }

    /// Ends the search: the results give way to the list the Vault was on.
    /// The bar has already folded itself back into the icon when it calls this.
    func closeVaultSearch() {
        vaultSearch.cancel(nostrService: nostrService)
        searchQueryDraft = ""
        withAnimation(Motion.toggle) { isSearchActive = false }
    }

    func runVaultSearch(now: Bool = false) {
        vaultSearch.search(searchQueryDraft, now: now,
                           nostrService: nostrService, feedService: feedService,
                           blocked: configService.activeAccountBlockedHexPubkeys)
    }

    @ViewBuilder
    var searchBar: some View {
        if isSearchActive {
            VaultSearchBar(text: $searchQueryDraft,
                           focusRequest: searchFocusRequest,
                           onSubmit: { runVaultSearch(now: true) },
                           onClose: closeVaultSearch)
                .onChange(of: searchQueryDraft) { _, _ in runVaultSearch() }
        }
    }

    var vaultSearchResults: some View {
        VaultSearchResults(model: vaultSearch,
                           onProfile: { showingProfilePubkey = $0 },
                           onNote: { openNote($0) })
            .environment(\.openURL, nostrLinkAction)
    }

    var filterView: some View {
        HStack(spacing: 2) {
            FilterButton(title: "All", color: .secondary, isSelected: contentFilter == .all) {
                tapFilter(.notes(.all), contentFilter == .all) { contentFilter = .all }
            }
            FilterButton(title: "My Notes", color: .havenPurple, isSelected: contentFilter == .mine) {
                tapFilter(.notes(.mine), contentFilter == .mine) { contentFilter = .mine }
            }
            FilterButton(title: "Tagged", color: Color.havenVerified, isSelected: contentFilter == .tagged) {
                tapFilter(.notes(.tagged), contentFilter == .tagged) { contentFilter = .tagged }
            }
            FilterButton(title: "Whitelisted", color: Color.havenVerified.opacity(0.7), isSelected: contentFilter == .whitelist) {
                tapFilter(.notes(.whitelist), contentFilter == .whitelist) { contentFilter = .whitelist }
            }
            FilterButton(title: "Outside Network", color: .orange, isSelected: contentFilter == .outside) {
                tapFilter(.notes(.outside), contentFilter == .outside) { contentFilter = .outside }
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
                tapFilter(.likes(.onMyNotes), likesFilter == .onMyNotes) { likesFilter = .onMyNotes }
            }
            FilterButton(title: "My Likes", icon: "heart", color: .pink, isSelected: likesFilter == .myLikes) {
                tapFilter(.likes(.myLikes), likesFilter == .myLikes) { likesFilter = .myLikes }
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
                tapFilter(.followers(.new), followersFilter == .new) { followersFilter = .new }
            }
            FilterButton(title: "All", icon: "person.3.fill", color: .secondary, isSelected: followersFilter == .all) {
                tapFilter(.followers(.all), followersFilter == .all) { followersFilter = .all }
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
                tapFilter(.zaps(.onMyNotes), zapsFilter == .onMyNotes) { zapsFilter = .onMyNotes }
            }
            FilterButton(title: "My Zaps", icon: "bolt", color: .yellow, isSelected: zapsFilter == .myZaps) {
                tapFilter(.zaps(.myZaps), zapsFilter == .myZaps) { zapsFilter = .myZaps }
            }
        }
        .padding(4)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.8))
    }
}
