import Foundation

/// Edit Profile starts from the newest kind 0 on the relays and keeps every
/// field the form doesn't show. When one of those hidden fields (or a tag)
/// holds a working nsec, the signer would refuse every save and the person
/// could never see where the key is. So the hidden field is left out of the
/// new profile and the person is told which one: this publishes less, never
/// the key (Tron, #2314). A key in what the form shows is blocked by the form
/// instead, so the person removes it themselves.
enum ProfileSecretKeyStrip {
    struct Result {
        var fields: [String: Any]
        var tags: [[String]]
        /// The field names (and "<name> tag") left out, in a stable order.
        var removed: [String]

        /// "Removed a secret key from about." Nil when nothing was removed.
        /// Names the field only, never the key.
        var message: String? {
            removed.isEmpty ? nil : "Removed a secret key from \(removed.joined(separator: ", "))."
        }
    }

    static func strip(_ merged: [String: Any], tags: [[String]]) -> Result {
        var fields = merged
        var removed: [String] = []
        // Call after the form's own check (which blocks a key the person typed
        // or can see): a key still here came from the relays' copy, in a
        // field the form doesn't show or a newer value it never showed.
        for key in merged.keys.sorted() {
            if SecretKeyLeak.containsSecretKey(text(merged[key])) {
                fields.removeValue(forKey: key)
                removed.append(key)
            }
        }
        var kept: [[String]] = []
        for tag in tags {
            if tag.contains(where: SecretKeyLeak.containsSecretKey) {
                removed.append("\(tag.first ?? "a") tag")
            } else {
                kept.append(tag)
            }
        }
        return Result(fields: fields, tags: kept, removed: removed)
    }

    /// A field's value as text: a string as is, anything else (a number, a
    /// list, an object) as its JSON.
    private static func text(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
