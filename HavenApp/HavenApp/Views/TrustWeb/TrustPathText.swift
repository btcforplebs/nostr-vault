import SwiftUI

/// The one-line summary shared by the card and the expanded view.
enum TrustPathText {
    static func label(_ path: TrustPath?, name: (String) -> String) -> String {
        guard let path else { return "Tracing how they reach you…" }
        switch path.reach {
        case .you:
            return "This is you."
        case .follow:
            return path.bridges.isEmpty
                ? "You follow them · 1 hop"
                : "You follow them · also followed by \(bridgeNames(path, name: name))"
        case .bridged:
            return "Followed by \(bridgeNames(path, name: name)) you follow · 2 hops"
        case .web:
            return "In your Web of Trust"
        case .outside:
            return "Not in your web · no one you follow follows them"
        case .unknown:
            return "Your trust graph isn't loaded yet"
        }
    }

    private static func bridgeNames(_ path: TrustPath, name: (String) -> String) -> String {
        let names = path.bridges.prefix(2).map(name)
        let rest = path.bridges.count - names.count
        if rest > 0 || path.hasMore { return names.joined(separator: ", ") + " + more" }
        return names.joined(separator: " and ")
    }
}
