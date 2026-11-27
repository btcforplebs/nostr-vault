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
@MainActor
final class FeedScreenWatch: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private var missedChange = false

    /// False behind another tab or under a pushed page.
    var isOnScreen = true {
        didSet {
            guard isOnScreen != oldValue, isOnScreen, missedChange else { return }
            missedChange = false
            objectWillChange.send()
        }
    }

    init() {
        let sources: [ObservableObjectPublisher] = [
            FeedService.shared.objectWillChange,
            NostrService.shared.objectWillChange,
            ConfigService.shared.objectWillChange,
            RelayProcessManager.shared.objectWillChange,
            RecipeFeedService.shared.objectWillChange,
            MarketplaceFeedService.shared.objectWillChange,
            LiveFeedService.shared.objectWillChange,
            ReelsFeedService.shared.objectWillChange,
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

    private func changed() {
        if isOnScreen { objectWillChange.send() } else { missedChange = true }
    }
}
