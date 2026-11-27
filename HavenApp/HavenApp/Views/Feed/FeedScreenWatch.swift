import SwiftUI
import Combine

/// What the Feed screen observes, forwarded only while the Feed is on
/// screen. Feed tab perf review 11-27 #4: the iOS TabView keeps FeedView
/// mounted on purpose (`FeedView+RootContent.swift`), so while you sat on
/// Vault each incoming note still ran FeedView.body and redrew the thread
/// cards (10 live notes: 20 FeedView bodies, 280 card bodies) with nothing
/// on screen.
///
/// While hidden, a change is only noted; coming back sends one change, so
/// the Feed draws once with everything that arrived. The row cache and the
/// thread grouping keep themselves current while hidden
/// (RowDataCacheObservers), and `onReceive` subscriptions still run.
///
/// The Feed's own row store lives here too, so the row writes those
/// observers make while hidden (likes, zaps, stats, profiles) don't run
/// FeedView.body either.
@MainActor
final class FeedScreenWatch: ObservableObject {
    /// Row data, thread grouping and Popular ranks; see FeedRowStore.
    let rowStore = FeedRowStore()
    private var cancellables = Set<AnyCancellable>()
    private var missedChange = false

    /// False while the Feed is hidden: behind another tab, or on the iPad,
    /// under a page pushed in its own stack. On iPhone a pushed thread
    /// covers the whole stack, which stays on screen.
    private(set) var isOnScreen = true

    init() {
        let sources: [ObservableObjectPublisher] = [
            rowStore.objectWillChange,
            FeedService.shared.objectWillChange,
            NostrService.shared.objectWillChange,
            ConfigService.shared.objectWillChange,
            RelayProcessManager.shared.objectWillChange,
            RecipeFeedService.shared.objectWillChange,
            MarketplaceFeedService.shared.objectWillChange,
            LiveFeedService.shared.objectWillChange,
            ReelsFeedService.shared.objectWillChange,
            TutorialCenter.shared.objectWillChange,
            FillYourVaultCoordinator.shared.objectWillChange,
        ]
        // Forwarded at once, not throttled: while on screen the Feed redraws
        // exactly as it did when it observed these itself.
        for source in sources {
            source.sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.changed() }
                } else {
                    DispatchQueue.main.async { self?.changed() }
                }
            }.store(in: &cancellables)
        }
    }

    /// The Feed is on screen again. True when something changed while it
    /// was hidden; that change is sent now.
    @discardableResult
    func show() -> Bool {
        guard !isOnScreen else { return false }
        isOnScreen = true
        guard missedChange else { return false }
        missedChange = false
        objectWillChange.send()
        return true
    }

    func hide() { isOnScreen = false }

    private func changed() {
        if isOnScreen { objectWillChange.send() } else { missedChange = true }
    }
}
