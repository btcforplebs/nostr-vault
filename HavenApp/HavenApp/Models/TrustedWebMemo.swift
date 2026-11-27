import Foundation

/// Remembers the last web it built (`TrustMap.web`, or `AccountWeb.web` with
/// a scope). `feedTrustedPubkeys` is read on every feed recompute and every
/// Global check, and each read built a fresh union of a graph of thousands
/// (Mac sweep 11-01 #3). An unchanged graph and follow list compare by
/// identity, so a repeat read costs nothing. Safe from any thread.
final class TrustedWebMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (saved: Set<String>, follows: [String], scope: AccountWebScope?, generation: Int, web: Set<String>)?
    /// The relay's links file and depth, from the same read as the graph.
    private var links: TrustLinksIndex?
    private var depth: Int?
    /// Bumped on every `load`, so a new links file rebuilds the web without
    /// comparing tens of thousands of entries on every read.
    private var generation = 0

    /// The links and depth that came with the graph just read (`readWotCache`).
    func load(links: TrustLinksIndex?, depth: Int?) {
        lock.lock(); defer { lock.unlock() }
        self.links = links
        self.depth = depth
        generation += 1
    }

    /// A graph read without its links (main-thread reads): the depth now,
    /// the links when their off-main parse lands (`load(links:)`).
    func load(depth: Int?) {
        lock.lock(); defer { lock.unlock() }
        self.depth = depth
        generation += 1
    }

    /// A links file has been loaded (the first read parses it on the spot).
    var hasLinks: Bool {
        lock.lock(); defer { lock.unlock() }
        return links != nil
    }

    func load(links: TrustLinksIndex?) {
        lock.lock(); defer { lock.unlock() }
        self.links = links
        generation += 1
    }

    /// The web for `follows`. With a `scope`, the open account's own web
    /// (`AccountWeb`); without, the relay's shared web plus the follows.
    func web(saved: Set<String>, follows: [String], scope: AccountWebScope? = nil) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let last, last.saved == saved, last.follows == follows, last.scope == scope,
           last.generation == generation {
            return last.web
        }
        let web = scope.map {
            AccountWeb.web(saved: saved, follows: Set(follows), links: links, depth: depth, scope: $0)
        } ?? TrustMap.web(saved: saved, follows: Set(follows))
        last = (saved, follows, scope, generation, web)
        return web
    }

    private var lastLayers: (saved: Set<String>, follows: [String], scope: AccountWebScope, generation: Int,
                             layers: (web: Set<String>, loose: Set<String>))?

    /// The one gate's web and the hop past it (`WebGate.layers`), from the
    /// same graph, links and depth, remembered like `web`.
    func layers(saved: Set<String>, follows: [String], scope: AccountWebScope) -> (web: Set<String>, loose: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        if let lastLayers, lastLayers.saved == saved, lastLayers.follows == follows, lastLayers.scope == scope,
           lastLayers.generation == generation {
            return lastLayers.layers
        }
        let layers = WebGate.layers(saved: saved, follows: Set(follows), links: links, depth: depth, scope: scope)
        lastLayers = (saved, follows, scope, generation, layers)
        return layers
    }

    private var lastGate: (saved: Set<String>, follows: [String], scope: AccountWebScope, generation: Int,
                           whitelist: Set<String>, blocked: Set<String>, mutes: MuteList, gate: WebGate.Web)?

    /// The whole gate for one account, remembered: feeds read it on every
    /// recompute, and building it lowercases sets of thousands of keys.
    func gate(saved: Set<String>, follows: [String], scope: AccountWebScope, whitelist: Set<String>,
              blocked: Set<String>, mutes: MuteList) -> WebGate.Web {
        let layers = self.layers(saved: saved, follows: follows, scope: scope)
        lock.lock(); defer { lock.unlock() }
        if let lastGate, lastGate.saved == saved, lastGate.follows == follows, lastGate.scope == scope,
           lastGate.generation == generation, lastGate.whitelist == whitelist, lastGate.blocked == blocked,
           lastGate.mutes == mutes {
            return lastGate.gate
        }
        let gate = WebGate.Web(own: scope.owners, whitelist: whitelist, web: layers.web, loose: layers.loose,
                               blocked: blocked, mutes: mutes)
        lastGate = (saved, follows, scope, generation, whitelist, blocked, mutes, gate)
        return gate
    }

    /// Which of `follows` follow `target`, from the relay's links file
    /// (each entry lists the follows that follow that key). Empty with no
    /// links file. Lets a profile count followers inside your web without
    /// fetching anyone's contact list.
    func followers(of target: String, among follows: Set<String>) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard let links, let from = links.links[target.lowercased()] else { return [] }
        var out = Set<String>()
        for index in from where links.follows.indices.contains(index) {
            let key = links.follows[index]
            if follows.contains(key) { out.insert(key) }
        }
        return out
    }
}
