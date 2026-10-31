import SwiftUI

extension FeedView {
    // MARK: - Web of Trust / Everyone

    /// Who every Global view shows (Global, and Media, Articles, diVines,
    /// Recipes, Live and Marketplace on Global): the shield is your Web of
    /// Trust, the crossed-out shield is everyone. Not a globe: Global's own
    /// button already is one, so Everyone read as a second Global. One
    /// app-wide setting, one button so the pill keeps its width. Everyone is the only step behind the
    /// sensitive-content warning.
    @ViewBuilder
    var trustScopeButton: some View {
        let everyone = configService.config.globalShowsEveryone
        // The shield wears a lock while Everyone can't be turned on yet.
        let locked = TrustScopeLock.isLocked(followCount: feedService.trustLockFollowCount, everyoneIsOn: everyone)
        let shield = everyone ? "shield.slash.fill" : (locked ? "lock.shield.fill" : "checkmark.shield.fill")
        #if os(macOS)
        Button(action: toggleTrustScope) {
            Image(systemName: shield)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(everyone ? Color.orange : Color.havenPurple)
        }
        .buttonStyle(.plain)
        .help(everyone ? "Everyone: unfiltered posts. Click for your Web of Trust"
              : locked ? "Web of Trust. Everyone unlocks once you follow \(TrustScopeLock.followsNeeded) people"
              : "Web of Trust: people you follow and the people they follow. Click for everyone")
        #else
        IconFilterButton(icon: shield, tooltip: everyone ? "Everyone" : "Web of Trust", isSelected: true, color: everyone ? .orange : .havenPurple, action: toggleTrustScope)
        #endif
    }

    @ViewBuilder
    var trustScopeMenuItems: some View {
        Button {
            setGlobalShowsEveryone(false)
        } label: {
            Label("Web of Trust", systemImage: configService.config.globalShowsEveryone ? "checkmark.shield" : "checkmark")
        }
        Button {
            if !configService.config.globalShowsEveryone { requestEveryone() }
        } label: {
            Label("Everyone", systemImage: configService.config.globalShowsEveryone ? "checkmark" : "shield.slash")
        }
    }

    /// Articles' Following / Global. Global starts on the Web of Trust, so it
    /// needs no warning; only the shield's Everyone does.
    /// Media's Global: the Web of Trust by default, like every Global view.
    func setMediaGlobal() {
        guard feedService.mediaFeedMode != .global else { return }
        feedService.mediaFeedMode = .global
        feedService.refresh()
    }

    func setArticlesFeedMode(_ mode: MediaFeedMode) {
        guard feedService.articlesFeedMode != mode else { return }
        feedService.articlesFeedMode = mode
        feedService.refresh()
    }

    /// Reads the setting at tap time rather than from the last render.
    private func toggleTrustScope() {
        if configService.config.globalShowsEveryone {
            setGlobalShowsEveryone(false)
        } else {
            requestEveryone()
        }
    }

    /// Turning Everyone on: the sensitive-content warning, or while the
    /// account follows too few people, why it is locked (`TrustScopeLock`).
    func requestEveryone() {
        if TrustScopeLock.isLocked(followCount: feedService.trustLockFollowCount, everyoneIsOn: false) {
            showingTrustLock = true
        } else {
            showingGlobalEveryoneWarning = true
        }
    }

    func setGlobalShowsEveryone(_ on: Bool) {
        guard configService.config.globalShowsEveryone != on else { return }
        configService.config.globalShowsEveryone = on
        configService.save()
    }

    /// Runs on every flip of the shield, here or on a hashtag sheet. Re-filters
    /// straight away, then reloads, so the switch visibly lands both ways:
    /// back to the Web of Trust the untrusted posts go at once instead of
    /// lingering in the list and the new-posts count.
    func reloadForTrustScope() {
        feedService.recomputeFilteredNotes()
        // The shield is one app-wide setting; feeds with their own service
        // refetch under it, the note feeds re-filter and reload.
        switch feedService.feedMode {
        case .reels: reelsService.refresh()
        case .recipes: recipeService.refresh()
        case .live: liveService.refresh()
        case .marketplace: marketplaceService.refresh()
        // Following and the like never use the shield; a flip from a hashtag
        // sheet must not reload them.
        default: if feedService.isGlobalLikeMode { feedService.refresh() }
        }
    }
}
