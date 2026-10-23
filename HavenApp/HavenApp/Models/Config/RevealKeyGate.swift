import Foundation

/// Reveal Private Key's password rule. The key shows only for a password the
/// user typed: an empty field never falls back to the password saved on this
/// device, so device-owner authentication (the phone passcode) alone can
/// never show the nsec.
enum RevealKeyGate {
    /// The password to decrypt with, or nil when nothing was typed.
    static func password(typed: String) -> String? {
        typed.isEmpty ? nil : typed
    }
}
