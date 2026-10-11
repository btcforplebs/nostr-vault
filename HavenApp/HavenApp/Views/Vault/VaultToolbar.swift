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
        vaultTabHostsMedia && viewMode == .notes && noteScope != .notes && searchScope != .profiles
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
    /// icons. A filter tap says what it picked in the note under the bar.
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

    // MARK: - Filter note

    /// A filter tap's note. A list rebuilt off the main thread (Notes,
    /// Likes, Zaps) is counted when it lands; "checking…" shows only if
    /// that takes a moment.
    func noteFilterTap(_ choice: VaultFilterChoice, changed: Bool) {
        if choice == .recipes && !recipesOnly {
            pendingFilterNote = nil
            filterNote.show(.off("Recipes"))
            return
        }
        guard changed, choice.waitsForList else {
            pendingFilterNote = nil
            filterNote.show(filterNoteText(choice))
            return
        }
        pendingFilterNote = choice
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard pendingFilterNote == choice else { return }
            filterNote.show(FilterNote(icon: choice.icon, text: "\(choice.name(scope: noteScope)) · checking…"))
        }
    }

    /// A rebuilt list landed: the waiting note can count it now.
    func filterListLanded() {
        guard let choice = pendingFilterNote else { return }
        pendingFilterNote = nil
        filterNote.show(filterNoteText(choice))
    }

    /// "Mentions · 18", or "No mentions yet" rather than a 0. A list that
    /// stopped at its page size says so with a "+".
    func filterNoteText(_ choice: VaultFilterChoice) -> FilterNote {
        let (count, capped) = filterCount(choice)
        let text = count == 0
            ? choice.emptyText(scope: noteScope)
            : "\(choice.name(scope: noteScope)) · \(count.formatted())\(capped ? "+" : "")"
        return FilterNote(icon: choice.icon, text: text)
    }

    private func filterCount(_ choice: VaultFilterChoice) -> (Int, Bool) {
        switch choice {
        case .activity(let filter):
            let zapsOnly = configService.config.zapsOnlyMode
            let n = displayActivity.filter { filter.includes($0.kind) && !(zapsOnly && $0.kind == .reaction) }.count
            return (n, displayActivity.count >= maxDisplayedItems)
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
            FilterButton(title: "Outside Network", color: .orange, isSelected: contentFilter == .outside) {
                contentFilter = .outside
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
