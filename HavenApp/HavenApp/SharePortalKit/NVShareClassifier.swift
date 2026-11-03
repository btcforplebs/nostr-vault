import Foundation

// MARK: - Share classifier
//
// What was shared → the actions worth offering, most likely first. Pure, and
// the rules are docs/SHARE_PORTAL_CONTRACT.md §3, mirrored line for line by
// Android's ShareClassifier.kt and tested with the same JSON fixtures. A
// change here is a change there.

struct NVShareInput: Equatable, Sendable {
    struct FileInfo: Equatable, Sendable {
        var mime: String
        var name: String
    }

    var url: String?
    var title: String?
    var text: String?
    var selection: String?
    var files: [FileInfo] = []
    var ldTypes: [String] = []
}

enum NVShareClassifier {
    static func classify(_ input: NVShareInput) -> [NVShareAction] {
        let webURL = webURL(of: input)
        let haystack = [input.url, input.text, input.selection].compactMap { $0 }.joined(separator: "\n")
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selection = input.selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let pay = matches(bolt11, in: haystack) || matches(lnurl, in: haystack) || isLightningAddress(text)
        let profile = matches(npub, in: haystack) || matches(nprofile, in: haystack)
        let calendar = input.files.contains { $0.mime.lowercased() == "text/calendar" || $0.name.lowercased().hasSuffix(".ics") }
            || input.ldTypes.contains("Event")
        let recipe = input.ldTypes.contains("Recipe")
        let media = input.files.contains { isMedia($0) }
        let pdf = input.files.contains { $0.mime.lowercased() == "application/pdf" || $0.name.lowercased().hasSuffix(".pdf") }
        let status = webURL.map(isMusicOrVideo) ?? false
        let otherFile = input.files.contains { !isMedia($0) }

        var out: [NVShareAction] = []
        func add(_ actions: NVShareAction...) {
            for a in actions where !out.contains(a) { out.append(a) }
        }
        if pay { add(.pay) }
        if profile { add(.profile) }
        if calendar { add(.calendar) }
        if !selection.isEmpty { add(.highlight) }
        if media { add(.upload, .mediaPost) }
        if pdf { add(.privateCopy) }
        if recipe { add(.recipe) }
        if status { add(.status) }
        if webURL != nil { add(.bookmark, .articleClip, .highlight, .privateCopy, .dm, .label) }
        else if !text.isEmpty { add(.highlight, .dm) }
        if otherFile { add(.dm) }
        return out
    }

    /// `url` when it is http(s), else the first http(s) link in `text`.
    static func webURL(of input: NVShareInput) -> String? {
        if let url = input.url?.trimmingCharacters(in: .whitespacesAndNewlines), isWeb(url) { return url }
        guard let text = input.text,
              let range = text.range(of: #"(?i)https?://[^\s<>"]+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func isWeb(_ s: String) -> Bool {
        let lower = s.lowercased()
        return (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && lower.count > 8
    }

    private static func isMedia(_ f: NVShareInput.FileInfo) -> Bool {
        let m = f.mime.lowercased()
        return m.hasPrefix("image/") || m.hasPrefix("video/")
    }

    // MARK: Signals

    private static let bech32 = "[qpzry9x8gf2tvdw0s3jn54khce6mua7l]"
    private static let bolt11 = #"(?i)\b(?:lightning:)?ln(?:bc|tb|tbs|bcrt)[0-9a-z]{20,}\b"#
    private static let lnurl = #"(?i)\b(?:lightning:)?lnurl1[0-9a-z]{20,}\b"#
    private static let npub = "\\bnpub1\(bech32){58}\\b"
    private static let nprofile = "\\bnprofile1\(bech32){20,}\\b"
    private static let lightningAddress = #"(?i)^(?:lightning:)?[a-z0-9._-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}$"#

    private static func matches(_ pattern: String, in s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isLightningAddress(_ trimmedText: String) -> Bool {
        !trimmedText.isEmpty && trimmedText.count <= 320 && matches(lightningAddress, in: trimmedText)
    }

    static let musicHosts: Set<String> = [
        "open.spotify.com", "music.apple.com", "youtube.com", "youtu.be", "music.youtube.com",
        "soundcloud.com", "tidal.com", "wavlake.com", "fountain.fm",
    ]

    static func isMusicOrVideo(_ url: String) -> Bool {
        guard var host = host(of: url) else { return false }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return musicHosts.contains(host) || host.hasSuffix(".bandcamp.com")
    }

    /// True when both are URLs on the same host. Safari's canonical URL is
    /// only taken when it is on the page's own host.
    static func sameHost(_ a: String, _ b: String?) -> Bool {
        guard let b, let ha = host(of: a), let hb = host(of: b) else { return false }
        return ha == hb
    }

    /// The lowercase host of an http(s) URL, parsed by hand so Swift and
    /// Kotlin agree on odd input (no userinfo, port or IPv6 handling needed
    /// for a host-list match).
    static func host(of url: String) -> String? {
        let lower = url.lowercased()
        guard let schemeEnd = lower.range(of: "://") else { return nil }
        var rest = lower[schemeEnd.upperBound...]
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        return rest.isEmpty ? nil : String(rest)
    }
}
