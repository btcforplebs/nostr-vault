import SwiftUI

struct VaultChangeHandlers: ViewModifier {
    let viewMode: ViewMode
    let likesFilter: LikesFilter
    let zapsFilter: ZapsFilter
    let committedSearch: String
    let searchScope: SearchScope
    let contentFilter: ContentFilter
    let eventsCount: Int
    let blacklistedNpubs: [String]
    let activeAccountNpub: String
    let wotCount: Int
    /// A follow added in the app changes who counts as outside your network
    /// at once, without waiting for the relay's daily graph rebuild.
    let followCount: Int
    let onResetAndUpdate: () -> Void
    let onUpdate: () -> Void
    let onViewModeChange: (ViewMode) -> Void
    let onEventsChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: committedSearch) { _, _ in onResetAndUpdate() }
            .onChange(of: searchScope) { _, _ in onResetAndUpdate() }
            .onChange(of: contentFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: likesFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: zapsFilter) { _, _ in onResetAndUpdate() }
            .onChange(of: viewMode) { _, newMode in onViewModeChange(newMode) }
            .onChange(of: eventsCount) { _, _ in onEventsChange() }
            .onChange(of: blacklistedNpubs) { _, _ in onUpdate() }
            .onChange(of: activeAccountNpub) { _, _ in onResetAndUpdate() }
            .onChange(of: wotCount) { _, _ in onUpdate() }
            .onChange(of: followCount) { _, _ in onUpdate() }
    }
}
