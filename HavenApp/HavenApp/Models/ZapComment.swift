import Foundation

/// The words a zap carries (the zap request's `content`, NIP-57).
///
/// Only the user writes them. A one-tap zap carries nothing, and the amount
/// sheet's comment box is optional; there is no app-supplied default.
enum ZapComment {
    /// Longest comment the box accepts. Zap requests travel in the LNURL
    /// callback URL, so keep them short.
    static let maxLength = 280

    /// What the zap request carries for `typed`: trimmed, capped, or "" when
    /// the user wrote nothing.
    static func content(_ typed: String) -> String {
        String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }
}
