import Foundation

/// Which password-locked key (NIP-49 ncryptsec) Reveal Private Key offers to
/// copy: the one this device keeps, when it keeps one; otherwise (an older
/// plaintext key, which reveals without checking any password) the user picks
/// a new password, typed twice, as on Android (Tron, PR 1658).
enum LockedKeyExport {
    static let caption = "Your key locked with this password. Apps that take an ncryptsec (NIP-49) open it with the same password. Safer to move than the nsec."

    static let newPasswordCaption = "Choose the password that will open this copy. Apps that take an ncryptsec (NIP-49) open it with it."

    /// "" when `password` may lock a key (8 or more characters, typed the same twice), else why not.
    static func passwordProblem(_ password: String, _ confirm: String) -> String {
        if password.count < 8 { return "Password must be at least 8 characters" }
        if password != confirm { return "Passwords do not match" }
        return ""
    }

    /// The kept ncryptsec, or nil when there is none to hand over as it is.
    static func kept(_ stored: String?) -> String? {
        guard let clean = stored?.trimmingCharacters(in: .whitespacesAndNewlines), clean.hasPrefix("ncryptsec1") else { return nil }
        return clean
    }
}
