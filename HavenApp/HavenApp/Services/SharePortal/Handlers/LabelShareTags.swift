import Foundation

/// NIP-32 label (kind 1985) on a shared link (§6.5). Our own namespace and a
/// fixed list of labels, picked by Logen.
enum LabelShareTags {
    static let kind = 1985
    static let namespace = "app.nostrvault.link"
    static let labels = ["spam", "scam", "nsfw", "good"]

    /// Nil for a label not on the list.
    static func tags(label: String, url: String) -> [[String]]? {
        guard labels.contains(label) else { return nil }
        return [["L", namespace], ["l", label, namespace], ["r", url], ["alt", "Label: \(label) for \(url)"]]
    }
}
