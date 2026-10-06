import Foundation

/// Builds the kind-0 content an Edit Profile save publishes. A kind 0 replaces
/// the whole profile, so the new content starts from the newest one on the
/// relays and changes only the fields the user edited: lud06, bot and any key
/// the form does not show are kept.
enum ProfileMetadataMerge {
    /// The kind-0 keys the edit form shows.
    static let displayName = "display_name"
    static let name = "name"
    static let about = "about"
    static let picture = "picture"
    static let banner = "banner"
    static let nip05 = "nip05"
    static let lud16 = "lud16"
    static let website = "website"

    /// The JSON object in a kind-0 `content`; empty when there is none or it is
    /// not an object, since such content holds no keys to keep.
    static func parseContent(_ content: String?) -> [String: Any] {
        guard let data = content?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// `base` with each form field the user changed applied: `initial` is what
    /// the form showed when opened, `edited` what it holds now (both by kind-0
    /// key). A changed field overwrites its key, or removes it when cleared. An
    /// unchanged field leaves `base` alone, so a newer value on the relays than
    /// the cached one the form showed is not reverted.
    static func merge(base: [String: Any], initial: [String: String], edited: [String: String]) -> [String: Any] {
        var out = base
        for (key, raw) in edited {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == (initial[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { continue }
            if value.isEmpty { out.removeValue(forKey: key) } else { out[key] = value }
        }
        return out
    }

    /// `merged` as kind-0 content, or nil if it cannot be encoded.
    static func encode(_ merged: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One `NostrService.lookupNewestReplaceable` answer: the newest event, and how
/// many relays were asked and answered (EOSE). No event with every relay
/// answered means there genuinely is none, not that the lookup timed out.
struct ReplaceableLookup<Event> {
    let event: Event?
    let asked: Int
    let answered: Int

    var confirmedNone: Bool { event == nil && asked > 0 && answered >= asked }
}
