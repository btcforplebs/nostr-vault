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
            let key = textKey(post.content)
            guard seenText.insert(key).inserted else { continue }
            guard perAuthorCount[post.pubkey, default: 0] < perAuthor else { continue }
            perAuthorCount[post.pubkey, default: 0] += 1
            out.append(post.id)
        }
        return out
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
