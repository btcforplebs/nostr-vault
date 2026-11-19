import Foundation

/// Your own message coming back from the relay replaces the bubble shown
/// while it was sending, instead of standing next to it (B12, 2026-11-19).
/// The bubble carries a local UUID until then; a relay event's id is 64 hex.
/// Matching used to need the copy within 30 s, which a slow remote signer
/// (NIP-46) misses, so the message showed twice.
enum DMEchoMatch {
    /// A bubble that was never a relay event: the one shown while sending.
    static func isLocalPlaceholder(id: String) -> Bool {
        !(id.count == 64 && id.allSatisfy(\.isHexDigit))
    }

    /// Whether the relay's copy of your message `echoContent` is this bubble.
    /// A not-sent bubble is a different send and is never taken.
    static func isEcho(id: String, isFromMe: Bool, isFailed: Bool, content: String,
                       echoContent: String) -> Bool {
        isFromMe && !isFailed && content == echoContent && isLocalPlaceholder(id: id)
    }
}
