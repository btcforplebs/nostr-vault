import Foundation
import Combine

/// The globe's outer rings for the active account (`TrustMapOuter`), worked
/// out again only when the rank copy, your devices or your blocks change, not on every redraw of the globe. Android twin:
/// `service/TrustMapOuterWatch.kt`.
@MainActor
final class TrustMapOuterWatch: ObservableObject {
    static let shared = TrustMapOuterWatch()

    @Published private(set) var outer: TrustMapOuter = .none

    private var subscriptions: Set<AnyCancellable> = []

    #if os(macOS)
    private static let isDesktop = true
    #else
    private static let isDesktop = false
    #endif

    private init() {
        let store = DiscoveryReachStore.shared
        let config = ConfigService.shared
        store.$copy
            .map { _ in () }
            .merge(with: config.$config.map { _ in () })
            .merge(with: config.$activeAccountHexPubkey.map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
        update()
    }

    private func update() {
        let store = DiscoveryReachStore.shared
        let config = ConfigService.shared
        let next = TrustMapOuter.make(
            copy: store.copy,
            desktopPaired: TrustMapOuter.desktopPaired(config.config.meshDevices, isDesktop: Self.isDesktop),
            hidden: config.activeAccountBlockedHexPubkeys)
        if next != outer { outer = next }
    }
}
