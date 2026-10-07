import Foundation
import Combine

/// Applies `FillYourVaultRule` to the active account's follow list: starts the
/// guide for a new account, marks it done without showing it for an account
/// that already follows 5, and finishes it when the vault fills. Also keeps
/// Vault Master once earned. The guide's views read `meter` from here.
@MainActor
final class FillYourVaultCoordinator: ObservableObject {
    static let shared = FillYourVaultCoordinator()

    /// The meter for the active account, rebuilt on every follow change.
    @Published private(set) var meter = VaultMeter(follows: [], owner: "", masterEarned: false)
    /// Set when this account reaches Vault Master for the first time; the
    /// meter plays the gold bolt once and clears it.
    @Published var celebrateVaultMaster = false

    private let masterStore = VaultMasterStore()
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    /// Count the last time the rule ran, per account; nil before the list is known.
    private var lastCount: (account: String, count: Int)?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let feed = FeedService.shared
        // @Published fires before the new value is stored, so hop to the next
        // main-queue turn and read the settled state from the services.
        Publishers.Merge4(
            feed.$followedPubkeys.map { _ in () },
            feed.$isLoadingContacts.map { _ in () },
            feed.$contactListConfirmed.map { _ in () },
            ConfigService.shared.$activeAccountHexPubkey.map { _ in () }
        )
        .merge(with: feed.$hasAttemptedContactLoad.map { _ in () })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.update() }
        .store(in: &cancellables)
    }

    /// Closing the guide by hand: done past 5, skipped below.
    func close() {
        let account = ConfigService.shared.activeAccountHexPubkey
        switch FillYourVaultRule.onClose(count: meter.count) {
        case .done: TutorialCenter.shared.finish(.fillYourVault, account: account)
        default: TutorialCenter.shared.skip(.fillYourVault, account: account)
        }
    }

    private func update() {
        let feed = FeedService.shared
        let account = ConfigService.shared.activeAccountHexPubkey
        meter = VaultMeter(follows: feed.followedPubkeys, owner: account,
                           masterEarned: masterStore.isEarned(owner: account))

        let known = feed.followListIsKnown && !account.isEmpty
        let previous = lastCount?.account == account ? lastCount?.count : nil
        if known { lastCount = (account, meter.count) }

        if known, masterStore.record(meter, owner: account) {
            meter = VaultMeter(follows: feed.followedPubkeys, owner: account, masterEarned: true)
            celebrateVaultMaster = true
        }

        let center = TutorialCenter.shared
        switch FillYourVaultRule.onFollowsChanged(
            listKnown: known, previousCount: previous, count: meter.count,
            status: center.status(.fillYourVault, account: account),
            isActive: center.isActive(.fillYourVault)
        ) {
        case .none: break
        case .start: center.startIfEligible(.fillYourVault, account: account)
        case .finishSilently, .finish: center.finish(.fillYourVault, account: account)
        }
    }
}
