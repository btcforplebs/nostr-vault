import Foundation

/// The relay list a brand-new account picks in setup (Logen 2026-11-01).
/// It starts empty: we only recommend, the person chooses. Nothing is
/// published until they confirm, and only what they picked.
/// Android: the same rules, when its twin step is built.
struct SetupRelayChoice: Equatable {
    /// What we suggest: this device's write relays others can reach.
    let recommended: [String]
    /// What they picked, in the order they picked it.
    private(set) var chosen: [String] = []

    /// `picked`: what was chosen before (Back, then here again).
    init(recommended: [String], picked: [String] = []) {
        var seen = Set<String>()
        self.recommended = recommended.compactMap(Self.cleaned).filter { seen.insert(RelayMatrix.key($0)).inserted }
        for url in picked { add(url) }
    }

    /// Recommended relays not picked yet.
    var suggestions: [String] {
        recommended.filter { !contains($0) }
    }

    /// Whether every recommended relay is already picked.
    var hasAllRecommended: Bool { suggestions.isEmpty }

    func contains(_ url: String) -> Bool {
        let key = RelayMatrix.key(url)
        return chosen.contains { RelayMatrix.key($0) == key }
    }

    /// Adds every recommended relay not picked yet, after the ones picked.
    mutating func useRecommended() {
        for url in suggestions { chosen.append(url) }
    }

    /// Adds a relay typed or tapped. Returns false (and adds nothing) when
    /// it isn't a wss:// address others can reach or is already picked.
    @discardableResult
    mutating func add(_ raw: String) -> Bool {
        guard let url = Self.cleaned(raw), !contains(url) else { return false }
        chosen.append(url)
        return true
    }

    mutating func remove(_ url: String) {
        let key = RelayMatrix.key(url)
        chosen.removeAll { RelayMatrix.key($0) == key }
    }

    /// A typed address as a listable relay URL: trimmed, "wss://" added when
    /// no scheme was typed, trailing slashes dropped. Nil when it can't be a
    /// row of a published relay list (not wss, loopback, no host).
    static func cleaned(_ raw: String) -> String? {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if !url.contains("://") { url = "wss://" + url }
        url = HavenConfig.normalizedRelayURL(url)
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "wss",
              let host = parsed.host, !host.isEmpty, host.contains("."),
              RelayDraft.listable(url) else { return nil }
        return url
    }
}
