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
}
