import Foundation

/// Article clip (§6.1): quote + link, saved as a local article draft. Never a
/// copy of the page, never published from the share flow.
enum ArticleClipDraft {
    static func title(_ title: String?, url: String?) -> String {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return t }
        return url.flatMap(NVShareClassifier.host(of:)) ?? "Clipped link"
    }

    static func body(title: String, url: String?, selection: String?) -> String {
        var parts: [String] = []
        let quote = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !quote.isEmpty {
            parts.append(quote.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)"
            }.joined(separator: "\n"))
        }
        let line = sourceLine(label: title, url: url)
        if !line.isEmpty { parts.append(line) }
        return parts.joined(separator: "\n\n")
    }

    /// `Source: [label](url)`, escaped so a page title cannot break the link.
    static func sourceLine(label: String, url: String?) -> String {
        guard let url, !url.isEmpty else { return "" }
        let l = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let u = url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        return "Source: [\(l)](\(u))"
    }
}
