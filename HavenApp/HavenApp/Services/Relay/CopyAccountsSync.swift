import Foundation
import Combine

/// Keeps `copy-accounts.json` in the relay root current with this device's
/// accounts and names (docs/MESH_COPY_V2_CONTRACT.md §3.4), and asks the
/// person which accounts a copy or catch-up brought over to add here.
///
/// Logen's rule (2026-11-06): nothing is added on its own. The ticked ones
/// become look-only accounts (public key only: no nsec, no bunker, no saved
/// sign-in), through AddAccountsC now and the whitelist file for the next
/// relay start. Every note the copy carried stays in the vault either way,
/// and the engine never uploads anything by a brought-over account.
@MainActor
final class CopyAccountsSync: ObservableObject {
    static let shared = CopyAccountsSync()

    /// The accounts to ask about now (empty: nothing to ask).
    @Published private(set) var offered: [CopyAccounts.Account] = []

    private var watchers: Set<AnyCancellable> = []
    private static let settledKey = "copyAccounts.settled"

    private var fileURL: URL {
        ConfigService.shared.relayDataDir.appendingPathComponent(CopyAccounts.fileName)
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    /// Accounts never asked about again (hex): every one asked about, and
    /// every one that was own here, so removing an account later doesn't
    /// bring it back as an offer.
    private var settled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.settledKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.settledKey) }
    }

    func startWatching() {
        guard watchers.isEmpty else { return }
        writeOwn()
        refreshOffer()
        ConfigService.shared.$config
            .map(\.whitelistedNpubs)
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.writeOwn() }
            .store(in: &watchers)
        // Names arrive with profiles; the write is skipped when nothing changed.
        NostrService.shared.$profiles
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.writeOwn() }
            .store(in: &watchers)
    }

    // MARK: The file

    private func readFile() -> [CopyAccounts.Account] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        switch CopyAccounts.check(data) {
        case .success(let accounts): return accounts
        case .failure(let why):
            RelayProcessManager.shared.addLog("Copied accounts not used: \(why.rawValue)", level: "ERROR")
            return []
        }
    }

    /// This device's signing accounts (owner, or a stored key or signer),
    /// owner first, named from their profiles. Look-only accounts are never
    /// listed (Tron, #1810).
    private func ownAccounts() -> [CopyAccounts.Account] {
        let profiles = NostrService.shared.profiles
        return ConfigService.shared.signingAccountNpubs.compactMap { npub in
            guard let hex = MeshPairing.npubHex(npub) else { return nil }
            let p = profiles[hex]
            let raw = [p?.displayName, p?.name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let name = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(CopyAccounts.nameMax)))
            // A name that reads as a key is left out rather than refusing the file.
            return CopyAccounts.Account(npub: MeshPairing.npub(hex: hex), name: CopySettings.secretString(name) ? "" : name)
        }
    }

    private var ownHex: Set<String> {
        Set(ConfigService.shared.allAccountNpubs.compactMap { MeshPairing.npubHex($0) })
    }

    /// Writes the file when this device's accounts or names change. Never
    /// drops what a copy or catch-up merged in, except this device's own
    /// look-only accounts.
    func writeOwn() {
        let own = ownAccounts()
        guard !own.isEmpty else { return }
        settled.formUnion(ownHex)
        let existing = readFile()
        let signing = Set(own.compactMap { MeshPairing.npubHex($0.npub) })
        let next = CopyAccounts.ownFile(own: own, existing: existing, lookOnly: ownHex.subtracting(signing))
        guard next != existing, let data = CopyAccounts.fileData(next, updatedAt: Self.now) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    // MARK: The ask

    /// Reads what the engine merged in (after a copy or a catch-up) and
    /// offers the accounts this device lacks and was never asked about.
    func refreshOffer() {
        offered = CopyAccounts.offered(file: readFile(), ownHex: ownHex, settledHex: settled)
    }

    /// The person's answer: `ticked` become look-only accounts here; every
    /// offered one, ticked or not, is settled and not asked again.
    func answer(ticked: [CopyAccounts.Account]) {
        let asked = offered
        let chosen = asked.filter { a in ticked.contains { $0.npub == a.npub } }
        settled.formUnion(asked.compactMap { MeshPairing.npubHex($0.npub) })
        offered = []
        guard !chosen.isEmpty, let json = CopyAccounts.addJSON(chosen, updatedAt: Self.now) else { return }
        // Live now, without a relay restart.
        let added = json.withCString { AddAccountsC(UnsafeMutablePointer(mutating: $0)) }
        guard added >= 0 else {
            RelayProcessManager.shared.addLog("Accounts not added: the list was refused", level: "ERROR")
            return
        }
        // And in the whitelist file for the next relay start. Look-only: the
        // npub is all that is stored, no key or sign-in.
        let config = ConfigService.shared
        for a in chosen where !config.config.whitelistedNpubs.contains(a.npub) {
            config.config.whitelistedNpubs.append(a.npub)
        }
        config.save()
        RelayProcessManager.shared.addLog("Added \(chosen.count) brought-over account(s), look-only")
    }
}
