import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Pure event construction and signing helpers — no Combine, no SwiftUI.
/// Platform-specific signing backends (Go CGo, NIP-46) are called through
/// these helpers so the event-building logic is portable.
enum EventPublisher {

    // MARK: - Event Construction

    /// Builds an unsigned Nostr event dictionary ready for signing.
    /// This is the canonical event structure defined by NIP-01.
    static func buildUnsignedEvent(
        pubkey: String,
        kind: Int,
        content: String,
        tags: [[String]]
    ) -> [String: Any] {
        return [
            "pubkey": pubkey,
            "created_at": Int64(Date().timeIntervalSince1970),
            "kind": kind,
            "content": content,
            "tags": tags
        ]
    }

    /// Appends the client identification tag for kind-1 notes if not already present.
    /// Returns the updated tags array.
    static func appendClientTag(to tags: [[String]], kind: Int) -> [[String]] {
        guard kind == 1 || kind == NIP10Thread.commentKind, !tags.contains(where: { $0.first == "client" }) else { return tags }
        var result = tags
        #if os(iOS)
        let clientName: String
        if UIDevice.current.userInterfaceIdiom == .pad {
            clientName = "Nostr Vault on iPadOS"
        } else {
            clientName = "Nostr Vault on iOS"
        }
        #else
        let clientName = "Nostr Vault on MacOS"
        #endif
        result.append(["client", clientName])
        return result
    }

    // MARK: - Go Backend Signing

    /// Signs an event JSON string using the Go backend (SignEventC).
    /// Returns the decoded NostrEvent on success, nil on failure.
    static func signWithGoBackend(eventJSON: String, secretKey: String) -> NostrEvent? {
        guard let signedCStr = SignEventC(
            UnsafeMutablePointer(mutating: (eventJSON as NSString).utf8String),
            UnsafeMutablePointer(mutating: (secretKey as NSString).utf8String)
        ) else {
            #if DEBUG
            print("EventPublisher: SignEventC returned nil")
            #endif
            return nil
        }
        let signedStr = String(cString: signedCStr)
        free(signedCStr)
        return decodeSignedEvent(signedStr)
    }

    /// Signs an event with NIP-13 Proof of Work mining via the Go backend.
    /// Returns the decoded NostrEvent on success, nil on failure.
    static func mineAndSignWithGoBackend(
        eventJSON: String,
        secretKey: String,
        difficulty: Int,
        maxAttempts: Int
    ) -> NostrEvent? {
        guard let signedCStr = MineAndSignEventC(
            UnsafeMutablePointer(mutating: (eventJSON as NSString).utf8String),
            UnsafeMutablePointer(mutating: (secretKey as NSString).utf8String),
            Int32(difficulty),
            Int32(maxAttempts)
        ) else {
            #if DEBUG
            print("EventPublisher: MineAndSignEventC returned nil")
            #endif
            return nil
        }
        let signedStr = String(cString: signedCStr)
        free(signedCStr)
        return decodeSignedEvent(signedStr)
    }

    private static func decodeSignedEvent(_ jsonStr: String) -> NostrEvent? {
        guard let data = jsonStr.data(using: .utf8) else {
            #if DEBUG
            print("EventPublisher: Failed to convert signed JSON to Data")
            #endif
            return nil
        }
        do {
            return try JSONDecoder().decode(NostrEvent.self, from: data)
        } catch {
            #if DEBUG
            print("EventPublisher: Failed to decode signed event: \(error) — JSON: \(jsonStr.prefix(200))")
            #endif
            return nil
        }
    }

    // MARK: - Media Helpers

    /// Returns a MIME type for a URL based on its file extension, or nil if unknown.
    static func mimeFromExtension(_ url: URL) -> String? {
        SupportedMediaFormats.mime(forExtension: url.pathExtension)
    }

    /// Determines the media type from a MIME string, falling back to extension-based detection.
    nonisolated static func mediaTypeFromMime(_ mime: String?, url: URL) -> MediaItem.MediaType {
        if let mime = mime?.lowercased() {
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime.hasPrefix("image/") { return .image }
            if mime != "application/octet-stream" { return .unknown }
        }
        if url.isVideo { return .video }
        if url.isAudio { return .audio }
        return .image
    }
}

/// Checks an event received from a relay: its id must be the NIP-01 hash of
/// its contents and its sig a valid schnorr signature by its pubkey. A relay
/// can send anything under any id and any author; nothing else proves either.
enum NostrEventVerifier {
    static func isValid(_ event: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return false }
        return isValid(json: json)
    }

    static func isValid(json: String) -> Bool {
        json.withCString { VerifyEventC(UnsafeMutablePointer(mutating: $0)) } == 1
    }
}
