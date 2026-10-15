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
        layout.close = vouches.map { v in Set(layout.shell.filter { (v[$0] ?? 0) >= closeVouches }) } ?? []
        if wot {
            for layer in [Layer.everyone, .close, .furtherOut] {
                layout.layerFaces[layer] = layerFaceCandidates(layer, me: me, follows: follows, web: graph, vouches: vouches,
                                                               count: Int((Double(faceCandidateCount(for: layer)) * faceScale).rounded()))
            }
        }
        return layout
    }
}
