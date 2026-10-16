import Foundation

extension TrustMap {
    /// The globe's outer shells for one web: the haze sample, who in it is
    /// Close, and each layer's face candidates.
    struct HazeLayout: Equatable {
        var shell: [String] = []
        var close: Set<String> = []
        var layerFaces: [Layer: [String]] = [:]
    }

    /// Lays out the shells past your follows (`inner`). `faceScale` is how
    /// many more faces the globe shows than `TrustMap`'s counts.
    static func hazeLayout(graph: Set<String>, inner: Set<String>, vouches: [String: Int]?,
                           me: String, follows: Set<String>, wot: Bool, faceScale: Double) -> HazeLayout {
        var layout = HazeLayout()
        layout.shell = haze(graph.subtracting(inner))
        if wot {
            for layer in [Layer.everyone, .close, .furtherOut] {
                layout.layerFaces[layer] = layerFaceCandidates(layer, me: me, follows: follows, web: graph, vouches: vouches,
                                                               count: Int((Double(faceCandidateCount(for: layer)) * faceScale).rounded()))
            }
        }
        // Close is who someone is, by their vouches, not whether the haze
        // sample happened to take them. Faces are the most vouched and mostly
        // outside the sample: judged by the sample alone, nearly all of them
        // landed on the outer shell and the Discover ring had one or two.
        let shown = layout.shell + layout.layerFaces.values.joined()
        layout.close = vouches.map { v in Set(shown.filter { (v[$0] ?? 0) >= closeVouches }) } ?? []
        return layout
    }

    // MARK: Someone else's web

    /// Whose follow lists are fetched to map someone else's wider web: a
    /// spread of their follows, by key, so a big list still loads in seconds.
    static let widerSampleCap = 120

    static func widerSample(_ ring: [String]) -> [String] {
        haze(Set(ring), cap: widerSampleCap)
    }

    /// Someone else's web past their follows, from their follows' own lists:
    /// everyone those follow, and how many of the lists name each person (their
    /// vouches, as the relay counts yours). Only lists signed by someone in
    /// `ring` count, the newest per signer.
    static func widerWeb(of center: String, ring: [String],
                         lists: [[String: Any]]) -> (graph: Set<String>, vouches: [String: Int]) {
        let members = Set(ring)
        var newest: [String: [String: Any]] = [:]
        for list in lists {
            guard list["kind"] as? Int == 3, let signer = list["pubkey"] as? String,
                  members.contains(signer) else { continue }
            let at = (list["created_at"] as? Int) ?? 0
            if let kept = newest[signer], ((kept["created_at"] as? Int) ?? 0) >= at { continue }
            newest[signer] = list
        }
        var vouches: [String: Int] = [:]
        for (signer, list) in newest {
            for key in follows(of: signer, in: [list]) ?? [] where key != center {
                vouches[key, default: 0] += 1
            }
        }
        return (Set(vouches.keys), vouches)
    }

    /// The layer picker's people as a lit set, for a globe that isn't yours:
    /// it still lights your follows, your Vouched and your Further out, so
    /// you can see who in their web is close to you. nil for Everyone.
    static func layerLit(_ layer: Layer, me: String, follows: Set<String>, web: Set<String>,
                         vouches: [String: Int]?) -> Set<String>? {
        switch layer {
        case .everyone: return nil
        case .following: return follows.subtracting([me])
        case .close, .furtherOut:
            let people = layerPeople(layer, me: me, follows: follows, web: web, vouches: vouches)
            return Set(people.web)
        }
    }
}
