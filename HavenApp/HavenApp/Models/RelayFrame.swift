import Foundation

/// A relay message as the feed first reads it: its type (`EVENT`, `EOSE`,
/// `NOTICE`, …) and the whole array.
enum RelayFrame {
    /// nil for anything that isn't a JSON array starting with a string. A
    /// relay can send `[]`, and reading its first element by index traps:
    /// one malformed frame crashed the app (Tron, 10/15).
    static func parse(_ message: String) -> (type: String, json: [Any])? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [Any],
              let type = json.first as? String else { return nil }
        return (type, json)
    }
}
