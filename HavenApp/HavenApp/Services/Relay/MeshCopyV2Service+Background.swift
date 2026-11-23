#if os(iOS)
import UIKit

/// A copy or catch-up under way when the app leaves the screen gets
/// background time to finish (Logen, 2026-11-23). Before, the mesh engine
/// stopped 25 s after leaving and cut it ("copy catch-up stopped
/// error=unreachable"), so a phone never finished one with the Mac. The
/// engine's own grace waits for it too (FipsMeshService+KeepWarm).
extension MeshCopyV2Service {
    /// Takes background time when a run starts and gives it back when it
    /// ends. iOS ending the time first just gives it back: the run then
    /// stops with the engine and the next reconnect tries again.
    func holdBackgroundTime(_ running: Bool) {
        if running {
            guard backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "mesh-copy-catch-up") { [weak self] in
                MainActor.assumeIsolated { self?.holdBackgroundTime(false) }
            }
        } else if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
#endif
