import Foundation

/// Which wallet pays an account's zaps and invoices (design §6 "Cashu and
/// NWC side by side"): the NWC link or the built-in Cashu wallet. One choice
/// per account. No choice yet means NWC, so nothing changes until the user
/// picks Built-in in Settings › Wallet (step A3).
enum ZapWallet: String, CaseIterable {
    case nwc
    case cashu
}

enum PayZapsWith {
    static let keyPrefix = "nv.payZapsWith."

    static func key(accountHex: String) -> String { keyPrefix + accountHex.lowercased() }

    /// The account's choice; NWC when it has none (or an unknown value).
    static func choice(accountHex: String, defaults: UserDefaults = .standard) -> ZapWallet {
        stored(accountHex: accountHex, defaults: defaults) ?? .nwc
    }

    /// The saved choice itself, nil when the user never picked.
    static func stored(accountHex: String, defaults: UserDefaults = .standard) -> ZapWallet? {
        guard !accountHex.isEmpty, let raw = defaults.string(forKey: key(accountHex: accountHex)) else { return nil }
        return ZapWallet(rawValue: raw)
    }

    static func set(_ wallet: ZapWallet, accountHex: String, defaults: UserDefaults = .standard) {
        guard !accountHex.isEmpty else { return }
        defaults.set(wallet.rawValue, forKey: key(accountHex: accountHex))
    }

    /// Forgets the choice (the account is removed): back to NWC.
    static func clear(accountHex: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(accountHex: accountHex))
    }
}
