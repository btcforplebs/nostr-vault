import Foundation
import Combine

/// One person's Trust Path that stays current. It is traced again whenever
/// your web changes, so following someone turns their card into "You follow
/// them" at once, on any screen, without a refresh.
@MainActor
final class LiveTrustPath: ObservableObject {
    /// nil while it is being traced.
    @Published private(set) var path: TrustPath?
    private(set) var author: String?
    private var trace: Task<Void, Never>?
    private var changes: AnyCancellable?

    init() {
        changes = TrustPathService.webChanged.sink { [weak self] in self?.retrace() }
    }

    /// Follow `author`'s path from now on; nil stops. The same author again
    /// keeps the path it already has.
    func track(_ author: String?) {
        guard author != self.author else { return }
        self.author = author
        path = nil
        retrace()
    }

    /// The old answer stays on screen until the new one lands, so the card
    /// changes once instead of flashing empty, unless your follows now
    /// contradict it (`TrustPath.carried`).
    private func retrace() {
        trace?.cancel()
        guard let author else { trace = nil; return }
        path = TrustPath.carried(path, author: author, me: ConfigService.shared.activeAccountHexPubkey,
                                 follows: Set(FeedService.shared.followedPubkeys))
        trace = Task { [weak self] in
            let found = await TrustPathService.shared.path(for: author)
            guard !Task.isCancelled, let self, self.author == author else { return }
            NostrService.shared.fetchMissingProfiles(for: found.bridges)
            self.path = found
        }
    }
}
