import Foundation

/// JSON-LD from a shared page (docs/SHARE_PORTAL_CONTRACT.md §6.2): the
/// `<script type="application/ld+json">` blocks, a walk for the first object
/// of a schema.org type, and the text cleaning every value gets. Pure; the
/// page is untrusted and may be any size up to the fetcher's cap.
enum ShareLinkedData {
    static func blocks(_ html: String) -> [String] {
        let pattern = #"(?is)<script[^>]*type\s*=\s*["']?application/ld\+json["']?[^>]*>(.*?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// The first object whose `@type` is `type` (or a list holding it),
    /// through arrays and `@graph`, at most 4 levels down.
    static func first(_ type: String, in html: String) -> [String: Any]? {
        for block in blocks(html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            if let found = walk(json, type, depth: 0) { return found }
        }
        return nil
    }

    private static func walk(_ node: Any, _ type: String, depth: Int) -> [String: Any]? {
        guard depth <= 4 else { return nil }
        if let list = node as? [Any] {
            for item in list { if let f = walk(item, type, depth: depth + 1) { return f } }
            return nil
        }
        guard let dict = node as? [String: Any] else { return nil }
        if types(dict).contains(type) { return dict }
        if let graph = dict["@graph"] { return walk(graph, type, depth: depth + 1) }
        return nil
    }

    static func types(_ dict: [String: Any]) -> [String] {
        if let list = dict["@type"] as? [Any] { return list.compactMap { $0 as? String } }
        if let one = dict["@type"] as? String { return [one] }
        return []
    }

    /// Tags removed, entities decoded, whitespace collapsed, trimmed.
    static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        out = decodeEntities(out)
        out = out.replacingOccurrences(of: "\u{00A0}", with: " ")
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "#39": "'", "apos": "'", "nbsp": " ",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let entity = ns.substring(with: m.range(at: 1))
            result += replacement(entity) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func replacement(_ e: String) -> String? {
        if let n = named[e] { return n }
        var code: UInt32?
        if e.hasPrefix("#x") || e.hasPrefix("#X") { code = UInt32(e.dropFirst(2), radix: 16) }
        else if e.hasPrefix("#") { code = UInt32(e.dropFirst()) }
        guard let code, let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }

    /// The strings in a value that may be one string or a list of them.
    static func strings(_ value: Any?) -> [String] {
        if let s = value as? String { return [s] }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    static func text(_ dict: [String: Any], _ key: String) -> String {
        (dict[key] as? String).map(clean) ?? ""
    }
}
