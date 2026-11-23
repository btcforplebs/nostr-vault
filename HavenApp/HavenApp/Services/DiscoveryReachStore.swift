import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The active account's rank copy and who the Discovery reach bar lets in
/// (`DiscoveryReach`). Read again when the account or the bar changes, when
/// the app comes back to the front and when Settings › Feeds opens (the mesh
/// catch-up rewrites the file while the app is away); the
/// feed recomputes whenever the admitted set changes. Android twin:
/// `service/DiscoveryReachStore.kt`.
@MainActor
final class DiscoveryReachStore: ObservableObject {
    static let shared = DiscoveryReachStore()

    @Published private(set) var copy: TrustRankCopy?
    /// Empty with no copy.
    private(set) var admitted: DiscoveryReach.Admitted = .none
    /// The admitted distant people Discover asks the local feed store for
    /// (`DistantPostAuthors`), empty with no copy.
    private(set) var localDistantAuthors: [String] = []

    private var subscriptions: Set<AnyCancellable> = []
    private var load: Task<Void, Never>?

    private init() {
        let config = ConfigService.shared
        config.$activeAccountHexPubkey
            .removeDuplicates()
            .sink { [weak self] me in self?.reload(me) }
            .store(in: &subscriptions)
        config.$config
            .map(\.discoveryBar)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] saved in self?.apply(saved: saved) }
            .store(in: &subscriptions)
        #if canImport(UIKit)
        let foreground = UIApplication.willEnterForegroundNotification
        #else
        let foreground = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: foreground)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    /// The bar in use, nil with no copy.
    var bar: Double? {
        copy.map { DiscoveryReach.bar(saved: ConfigService.shared.config.discoveryBar, copy: $0) }
    }

    /// Reads the file again (cheap when it has not changed).
    func refresh() { reload(ConfigService.shared.activeAccountHexPubkey) }

    /// The gate a feed in `mode` judges with: `gate` plus the admitted
    /// people for Underrated and Discovery (your circle inside, distant
    /// connections rationed as loose), `gate` alone for every other.
    func gate(_ gate: WebGate.Web, for mode: FeedMode) -> WebGate.Web {
        guard DiscoveryReach.modes.contains(mode), !admitted.isEmpty else { return gate }
        var widened = gate
        widened.ranked = admitted.circle
        widened.rankedLoose = admitted.distant
        return widened
    }

    private func reload(_ me: String) {
        load?.cancel()
        // Another account's people never judge this one's feed, not even
        // while its own file loads.
        if let copy, copy.account != me {
            self.copy = nil
            apply(saved: nil)
        }
        load = Task { [weak self] in
            let copy = await TrustRankCopyStore.copy(for: me)
            guard !Task.isCancelled, let self else { return }
            // The store hands back the same copy while the file is unchanged;
            // compare the header, not 28,000 rows.
            if copy?.account != self.copy?.account || copy?.builtAt != self.copy?.builtAt
                || copy?.people.count != self.copy?.people.count {
                self.copy = copy
            }
            self.apply(saved: ConfigService.shared.config.discoveryBar)
        }
    }

    private func apply(saved: Double?) {
        let next = copy.map { DiscoveryReach.admitted($0, bar: DiscoveryReach.bar(saved: saved, copy: $0)) } ?? .none
        guard next != admitted else { return }
        admitted = next
        localDistantAuthors = DistantPostAuthors.pick(next.distant, copy: copy,
                                                      muted: ConfigService.shared.activeAccountBlockedHexPubkeys)
        FeedService.shared.recomputeFilteredNotes()
        // The live request to the local feed store carries the old list
        // otherwise: a bar move, a re-read rank file, or a copy that loaded
        // after Discover's first request went out.
        if FeedService.shared.feedMode == .discovery { FeedService.shared.reconcileFeedSubscriptions() }
    }
}
