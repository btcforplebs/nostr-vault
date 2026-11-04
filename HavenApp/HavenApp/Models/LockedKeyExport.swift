import Foundation

/// Which password-locked key (NIP-49 ncryptsec) Reveal Private Key offers to
/// copy: the one this device keeps, when it keeps one; otherwise (an older
/// plaintext key) a new one is locked with the password just typed.
enum LockedKeyExport {
    static let caption = "Your key locked with this password. Apps that take an ncryptsec (NIP-49) open it with the same password. Safer to move than the nsec."

    /// The kept ncryptsec, or nil when there is none to hand over as it is.
    static func kept(_ stored: String?) -> String? {
        guard let clean = stored?.trimmingCharacters(in: .whitespacesAndNewlines), clean.hasPrefix("ncryptsec1") else { return nil }
        return clean
    }
}
