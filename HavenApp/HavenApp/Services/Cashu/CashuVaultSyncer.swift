import Foundation
import Combine

/// When the built-in wallet talks to the Vault (A2): once per launch per
/// account, when the Vault relay is running and the account is active,
/// restore from the Vault (this is how a device with no wallet.json, such as
/// one restored from a backup, gets the wallet back), then publish anything
/// unsent (a spend the app died after, §4 risk 3) and read the copy back.
/// After every payment from the wallet, publish again.
///
/// One sync at a time per account. An account without a key or signer here,
/// or one the Vault doesn't take private posts from, is left alone. The
/// outcome per account is kept for the wallet screens (A3): only `noWallet`
/// lets them make a new wallet. Android twin: `service/cashu/CashuVaultSyncer.kt` (D2).
@MainActor
final class CashuVaultSyncer: ObservableObject {
    static let shared = CashuVaultSyncer()

    /// The last restore per account (hex).
    @Published private(set) var outcomes: [String: CashuRestoreOutcome] = [:]
    /// Where each account's wallet is kept, after the last read-back.
    @Published private(set) var copies: [String: CashuVaultCopies] = [:]
    /// The last publish per account that didn't finish (nil once one does).
    @Published private(set) var publishFailures: [String: String] = [:]

    private var restored: Set<String> = []
    private var running: Set<String> = []
    private var again: Set<String> = []
    private var subs = Set<AnyCancellable>()

    private init() {
        RelayProcessManager.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .running { self?.syncActive() }
            }
            .store(in: &subs)
        ConfigService.shared.$config
            .map(\.activeAccountNpub)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncActive() }
            .store(in: &subs)
    }

    /// Starts the watchers (called once at launch).
    static func start() { _ = shared }

    /// Restore (first time this launch) and publish for the active account.
    func syncActive() {
        guard RelayProcessManager.shared.state == .running else { return }
        let me = ZapPayer.activeAccountHex()
        guard Self.mayUseVault(me) else { return }
        run(me)
    }

    /// After a payment or any other change to `accountHex`'s wallet.
    func walletChanged(accountHex: String) {
        let me = accountHex.lowercased()
        guard CashuVaultLink.isActive(me), Self.mayUseVault(me) else { return }
        run(me)
    }

    private func run(_ me: String) {
        guard !running.contains(me) else {
            again.insert(me) // one more pass after the one in flight
            return
        }
        running.insert(me)
        Task { @MainActor in
            await self.pass(me)
            self.running.remove(me)
            if self.again.remove(me) != nil { self.run(me) }
        }
    }

    private func pass(_ me: String) async {
        let io = CashuVaultLink.io(accountHex: me)
        if !restored.contains(me) {
            let outcome = await CashuVaultSync.restore(accountHex: me, io: io)
            outcomes[me] = outcome
            switch outcome {
            case .restored, .noWallet:
                restored.insert(me)
            case .cantReachVault, .cantOpen, .keyConflict, .failed:
                return // tried again on the next relay start or account switch
            }
        }
        guard CashuWalletService.exists(accountHex: me),
              let wallet = try? CashuWalletService.wallet(accountHex: me) else { return }
        let result = await CashuVaultSync.publish(wallet, io: io)
        publishFailures[me] = result.failure
        let holds = await CashuVaultSync.vaultHoldsWallet(accountHex: me, io: io)
        let desktops = ConfigService.shared.config.meshDevices.filter { $0.role == .mac }.count
        copies[me] = CashuVaultCopies(thisVault: holds, desktopVaults: desktops)
    }

    /// The account has a key or signer here and may post to `/private`.
    static func mayUseVault(_ hex: String) -> Bool {
        guard hex.count == 64 else { return false }
        let config = ConfigService.shared.config
        guard let npub = config.vaultPrivateReaderNpubs.first(where: { ZapPayer.hex(ofNpub: $0) == hex }) else { return false }
        return config.canSignOnThisDevice(npub: npub)
    }
}
