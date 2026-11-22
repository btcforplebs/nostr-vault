import Foundation
import Combine

/// The active account's rank copy and who the Discovery reach bar lets in
/// (`DiscoveryReach`). Read again when the account or the bar changes, and
/// when Settings › Feeds opens (the mesh catch-up rewrites the file); the
/// feed recomputes whenever the admitted set changes. Android twin:
/// `service/DiscoveryReachStore.kt`.
@MainActor
final class DiscoveryReachStore: ObservableObject {
    static let shared = DiscoveryReachStore()

    @Published private(set) var copy: TrustRankCopy?
    /// Empty with no copy.
    private(set) var admitted: Set<String> = []

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
    }

    /// The bar in use, nil with no copy.
    var bar: Double? {
        copy.map { DiscoveryReach.bar(saved: ConfigService.shared.config.discoveryBar, copy: $0) }
    }

    /// Reads the file again (cheap when it has not changed).
    func refresh() { reload(ConfigService.shared.activeAccountHexPubkey) }

    /// The gate a feed in `mode` judges with: `gate` plus the admitted
    /// people for Underrated and Discovery, `gate` alone for every other.
    func gate(_ gate: WebGate.Web, for mode: FeedMode) -> WebGate.Web {
        guard DiscoveryReach.modes.contains(mode), !admitted.isEmpty else { return gate }
        var widened = gate
        widened.ranked = admitted
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
        let next = copy.map { DiscoveryReach.admitted($0, bar: DiscoveryReach.bar(saved: saved, copy: $0)) } ?? []
        guard next != admitted else { return }
        admitted = next
        FeedService.shared.recomputeFilteredNotes()
    }
}
