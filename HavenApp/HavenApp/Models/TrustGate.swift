/// Who may put words in front of you in replies, comments, quotes and live
/// chat: your Web of Trust, the same set and the same fail-closed rule as the
/// Global feed (`FeedService.globalTrustSet()`), plus the people a view always
/// shows (you, the note's author, the stream's host).
///
/// `trusted == nil` means the shield says Everyone: nobody is held back. An
/// empty set (no graph yet) holds back everyone outside `always`.
enum TrustGate {
    static func allows(_ author: String, trusted: Set<String>?, always: Set<String>) -> Bool {
        guard let trusted else { return true }
        return always.contains(author) || trusted.contains(author)
    }

    /// `items` split into the ones `allows` passes and the rest, order kept.
    static func split<T>(_ items: [T], author: (T) -> String,
                         trusted: Set<String>?, always: Set<String>) -> (inside: [T], outside: [T]) {
        guard trusted != nil else { return (items, []) }
        var inside: [T] = [], outside: [T] = []
        for item in items {
            if allows(author(item), trusted: trusted, always: always) { inside.append(item) } else { outside.append(item) }
        }
        return (inside, outside)
    }

    /// "3 replies from outside your web", "1 quote from outside your web".
    static func outsideLabel(count: Int, noun: String) -> String {
        let plural = noun == "reply" ? "replies" : noun + "s"
        return "\(count) \(count == 1 ? noun : plural) from outside your web"
    }
}
