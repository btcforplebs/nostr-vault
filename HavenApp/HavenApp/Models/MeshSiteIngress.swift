import Foundation

/// One ask for a loopback door to an npub's port 80 (`NvFipsIngress`), with
/// the reason when there is none, so the in-app browser can say which.
enum MeshSiteIngress: Equatable {
    /// `http://127.0.0.1:<port>/<token>`. Never log it: the path is the token.
    case ready(URL)
    /// The Mesh switch is off.
    case meshOff
    /// Mac: the engine is not running (it runs only with My Devices listed).
    case engineOff
    /// The middle server is set to None: no seeds, so no tree to reach strangers by.
    case noSeeds
    /// Up, but no tree parent yet (libnvfips -10): no route to anyone. Ask again.
    case notReady
    /// Anything else: the engine did not start or the door did not open.
    case failed

    /// libnvfips: ingress over the mesh with no tree parent (fips-v2-android `ERR_NO_TREE`).
    static let errNoTree: Int32 = -10

    init(failure rc: Int32) {
        self = rc == Self.errNoTree ? .notReady : .failed
    }

    var url: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }

    /// Worth asking again in a moment: the engine may find its parent.
    var isWaiting: Bool { self == .notReady }
}
