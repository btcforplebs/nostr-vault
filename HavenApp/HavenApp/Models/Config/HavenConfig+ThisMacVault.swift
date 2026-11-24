import Foundation

extension HavenConfig {
    /// The id of `thisMacVault`. Never a real Vault's: those are made from an
    /// address (DesktopVaultsLogic.id).
    static let thisMacVaultID = "this-mac"

    /// This Mac as a Vault on the owner's public lists (Desktop Vaults P8,
    /// §2.5 rule 3): its own domain, when the world can reach it, and its own
    /// mesh npub. Public on the web and "Media over the Mesh" switch these
    /// entries through DesktopVaultListEdit, as a phone's Vault switches do.
    /// It goes after the other Vaults in list order (rule 2).
    func thisMacVault(meshNpub: String?, name: String) -> DesktopVault {
        let reachable = !isLocal && !sanitizedRelayURL.isEmpty && !Self.isPrivateNetworkHost(sanitizedRelayURL)
        return DesktopVault(id: Self.thisMacVaultID, name: name, kind: .mac, meshNpub: meshNpub,
                            httpsURL: reachable ? "https://\(sanitizedRelayURL)" : nil, order: Int.max)
    }

    /// The Vaults a list edit on `thisMac` weighs (rules 1 and 2): every
    /// Desktop Vault in effect, then this Mac. A Vault that is this Mac by
    /// npub or host is left out, so its entries count once.
    func vaultsWithThisMac(_ thisMac: DesktopVault) -> [DesktopVault] {
        let ownNpub = thisMac.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:))
        let others = desktopVaultsInEffect.filter { vault in
            let sameNpub = ownNpub != nil && vault.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) == ownNpub
            let sameHost = thisMac.hostKey != nil && vault.hostKey == thisMac.hostKey
            return !sameNpub && !sameHost
        }
        return others + [thisMac]
    }

    /// Where Public on the web reads once its list edits are back (Tron
    /// should-fix 2 on #2512). `done`: per list, whether it ended the way the
    /// tap asked (published or unchanged). Off stays off only when every list
    /// dropped the domain, so a failed off reads on and another tap retries.
    /// On falls back to off only when no list took the domain: once one did,
    /// the switch must read on or a Relays save keeps it as an own row.
    static func publicOnWebAfterEdits(on: Bool, done: [Bool]) -> Bool {
        on ? done.contains(true) : !done.allSatisfy { $0 }
    }
}
