import Foundation

/// The switch above the Vault's search results (Logen dc9ea221): **Notes**
/// searches everything in the Vault, **My notes** only what the account in
/// use wrote (Logen 5d1ce4cb: the current account, not every added one).
/// The switch keeps its last setting. Pure, so MediaLogicTests compiles this
/// same file. Android twin: `ui/screens/vault/VaultSearchScope.kt`; web:
/// `screens/VaultSearch.jsx`.
enum VaultSearchScope: String, CaseIterable, Equatable {
    case all
    case mine

    /// Where the last setting is kept.
    static let defaultsKey = "vaultSearchScope"

    var title: String {
        switch self {
        case .all: return "Notes"
        case .mine: return "My notes"
        }
    }

    /// The saved setting; anything unknown reads as Notes.
    static func saved(_ raw: String?) -> VaultSearchScope {
        raw.flatMap(VaultSearchScope.init(rawValue:)) ?? .all
    }

    /// The `authors` the relay walk asks for: nil for Notes (no filter), the
    /// account's key for My notes. With no account there is no key, and My
    /// notes finds nothing rather than falling back to everyone.
    func authors(me: String) -> [String]? {
        switch self {
        case .all: return nil
        case .mine:
            let key = me.lowercased()
            return key.isEmpty ? [] : [key]
        }
    }

    /// Whether a matched note stays. The relay already filters by author;
    /// this is for the relay-down fallback, which searches what is in memory.
    func keepsNote(pubkey: String, me: String) -> Bool {
        switch self {
        case .all: return true
        case .mine: return !me.isEmpty && pubkey.caseInsensitiveCompare(me) == .orderedSame
        }
    }

    /// My notes is about what you wrote, so People hides.
    var showsPeople: Bool { self == .all }
}
