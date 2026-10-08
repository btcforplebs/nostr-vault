import Foundation

/// Which posts the topic feed shows to an account with no web of trust yet
/// (Fill your feed). Unfiltered, a tag like #bitcoin was ~95% bots and link
/// farms (sampled 2026-10-08: 569 posts → 29 from 23 people). Every rule here
/// is a fact about the post or its author, never a list of people we chose,
/// so nobody's web of trust is steered.
///
/// - The author follows at least `minFollows` people. Bots and farms almost
///   never follow anyone; people do. Unknown counts wait until looked up.
/// - Fewer than `maxHashtags` hashtags (hashtag stuffing).
/// - Not a link to a site that `farmAuthors`+ different accounts link to in
///   the same feed (how farms post). Images and video don't count.
/// - Not a copy of text already shown.
/// - At most `perAuthor` posts per person, so one voice can't fill the page.
/// - Not marked adult (#nsfw and the like, or a NIP-36 content warning).
/// - Not posted by an app or game on its player's behalf: the post's
///   `client` tag names the site it links to (Plebs vs. Zombies scores,
///   holdbtc). Sampled 2026-10-08 these were most of #nostr's leftover junk.
enum TopicFeedFilter {
    /// 20, not 10: the scheduled-content bots that got past 10 follow exactly
    /// 10 (sampled 2026-10-08: BTC Globe Live, Situation Room, Money Bot). At
    /// 30 real people start dropping out.
    static let minFollows = 20
    static let maxHashtags = 6
    static let farmAuthors = 4
    static let perAuthor = 2

    struct Post: Equatable {
        let id: String
        let pubkey: String
        let content: String
        let tags: [[String]]
    }

    /// `posts` newest first. `followCounts`: how many people each author
    /// follows (their kind 3), nil while unknown. Returns the ids to show,
    /// in the same order.
    static func shown(_ posts: [Post], followCounts: [String: Int]) -> [String] {
        var domainAuthors: [String: Set<String>] = [:]
        for post in posts {
            for domain in linkDomains(post.content) {
                domainAuthors[domain, default: []].insert(post.pubkey)
            }
        }
        let farms = Set(domainAuthors.filter { $0.value.count >= farmAuthors }.keys)

        var seenText = Set<String>()
        var perAuthorCount: [String: Int] = [:]
        var out: [String] = []
        for post in posts {
            guard let follows = followCounts[post.pubkey], follows >= minFollows else { continue }
            guard hashtagCount(post.tags) < maxHashtags else { continue }
            guard linkDomains(post.content).isDisjoint(with: farms) else { continue }
            guard !isAdult(post.tags), !isAppMade(post) else { continue }
            let key = textKey(post.content)
            guard seenText.insert(key).inserted else { continue }
            guard perAuthorCount[post.pubkey, default: 0] < perAuthor else { continue }
            perAuthorCount[post.pubkey, default: 0] += 1
            out.append(post.id)
        }
        return out
    }

    static let adultHashtags: Set<String> = ["nsfw", "porn", "xxx", "nude", "nudes", "onlyfans"]

    static func isAdult(_ tags: [[String]]) -> Bool {
        tags.contains { tag in
            tag.first == "content-warning"
                || (tag.count >= 2 && tag[0] == "t" && adultHashtags.contains(tag[1].lowercased()))
        }
    }

    /// The `client` tag and a linked site's name agree ("Plebs vs. Zombies"
    /// and plebsvszombies.cc): the app wrote this post, not the person.
    static func isAppMade(_ post: Post) -> Bool {
        let clients = post.tags.filter { $0.count >= 2 && $0[0] == "client" }.map { lettersOnly($0[1]) }
            .filter { $0.count >= 4 && !generalClients.contains($0) }
        guard !clients.isEmpty else { return false }
        let sites = linkDomains(post.content).map { host -> String in
            let labels = host.split(separator: ".")
            return lettersOnly(String(labels.count >= 2 ? labels[labels.count - 2] : labels.first ?? ""))
        }.filter { $0.count >= 4 }
        return clients.contains { client in sites.contains { client.contains($0) || $0.contains(client) } }
    }

    /// Everyday Nostr apps. Sharing a note's web link from the app you're in
    /// (Damus and damus.io) is a person posting, not the app (Tron, 2026-10-08).
    static let generalClients: Set<String> = [
        "damus", "primal", "primalandroid", "primalios", "snort", "coracle", "yakihonne",
        "nostrudel", "amethyst", "iris", "nostrich", "jumble", "ditto", "olas", "nostur",
        "nostrapp", "habla", "highlighter", "zapstore", "nostrvault", "haven",
    ]

    private static func lettersOnly(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// Different people (not the author) who must have replied, reposted,
    /// liked or zapped a post for it to go first. Sampled 2026-10-08 this
    /// left only people: #bitcoin 37 → 11, #nostr 71 → 11, no games or ads.
    static let minResponders = 2

    /// `ids` as `shown` returned them, with the posts people responded to
    /// moved to the front. Both groups keep their order; nothing is dropped.
    static func ordered(_ ids: [String], responders: [String: Int]) -> [String] {
        let answered = ids.filter { (responders[$0] ?? 0) >= minResponders }
        let rest = ids.filter { (responders[$0] ?? 0) < minResponders }
        return answered + rest
    }

    /// Who responded. A zap receipt (9735) is signed by the zap service, so
    /// the person is its `P` tag or the pubkey of the request inside it.
    static func responder(_ ev: [String: Any]) -> String? {
        guard (ev["kind"] as? Int) == 9735 else { return ev["pubkey"] as? String }
        let tags = ev["tags"] as? [[String]] ?? []
        if let sender = tags.first(where: { $0.count >= 2 && $0[0] == "P" })?[1] { return sender }
        guard let description = tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              let data = description.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return request["pubkey"] as? String
    }

    static func hashtagCount(_ tags: [[String]]) -> Int {
        tags.filter { $0.count >= 2 && $0[0] == "t" }.count
    }

    /// Lowercased, whitespace-collapsed, links dropped (farms vary the link).
    static func textKey(_ content: String) -> String {
        let words = content.lowercased().split(whereSeparator: \.isWhitespace)
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") && !$0.hasPrefix("nostr:") }
        return words.joined(separator: " ").prefix(120).description
    }

    private static let mediaExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "webm"]

    /// Hosts of the non-media links in a post.
    static func linkDomains(_ content: String) -> Set<String> {
        var out = Set<String>()
        for word in content.split(whereSeparator: \.isWhitespace) {
            guard word.hasPrefix("http://") || word.hasPrefix("https://"),
                  let url = URL(string: String(word)), let host = url.host?.lowercased() else { continue }
            if mediaExtensions.contains(url.pathExtension.lowercased()) { continue }
            out.insert(host)
        }
        return out
    }
}
