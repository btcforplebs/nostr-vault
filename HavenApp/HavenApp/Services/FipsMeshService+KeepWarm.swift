#if os(iOS)
import Foundation
import UIKit

/// Short trips out of the app keep the running mesh (MeshKeepWarm; Logen
/// 2026-11-14, routing audit fix 1). Leaving used to stop kiosk mode at once
/// and the client engine after 25 s with no background time held, so iOS
/// could freeze it first and it came back with a dead socket; coming back
/// then started it cold. Now both are kept for `MeshKeepWarm.grace` under a
/// background task of their own, and stopped as before if the app is still
/// away when it ends. Mac and Android are untouched.
extension FipsMeshService {
    /// The app left the screen with the engine up (kiosk mode or a client).
    /// Called by both background observers; one trip is counted once.
    func appLeftScreen() {
        guard let trip = awayClock.left(at: Date()) else { return }
        print("FipsMesh: app left the screen, mesh kept for \(Int(MeshKeepWarm.grace)) s")
        // Background time of its own, so the grace ends with a clean stop and
        // never with iOS freezing the engine. Its expiry stops it at once.
        // Each trip ends only its own task: a later trip's must outlive an
        // earlier trip's timer (Tron, #2052).
        endKeepWarmTask(trip: keepWarmTrip)
        keepWarmTrip = trip
        keepWarmTask = UIApplication.shared.beginBackgroundTask(withName: "mesh-keep-warm") { [weak self] in
            MainActor.assumeIsolated { self?.graceEnded(trip: trip) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + MeshKeepWarm.grace) { [weak self] in
            MainActor.assumeIsolated { self?.graceEnded(trip: trip) }
        }
    }

    /// The app is back on screen. Runs before kiosk mode or sharing-while-open
    /// is brought back, so a kept engine is found running and reused.
    func appReturned() {
        endKeepWarmTask(trip: keepWarmTrip)
        switch awayClock.returned(at: Date()) {
        case .none:
            return
        case .keep:
            if kioskActive || clientActive { print("FipsMesh: back on screen, mesh kept running") }
        case .restartIfUp:
            guard kioskActive || clientActive else { return }
            // The grace never ran: iOS froze the app with the engine up, and its
            // UDP socket is gone. Stop it; resumeIfWanted (or the next read)
            // starts it fresh.
            print("FipsMesh: back after \(Int(MeshKeepWarm.grace)) s with the engine still up (frozen), starting it fresh")
            if kioskActive { stopKiosk(leavingApp: true, notify: false) }
            dropClientEngine()
        }
    }

    /// Still away on `trip` when the grace (or its background time) ran out:
    /// stop as leaving the app always did.
    private func graceEnded(trip: Int) {
        defer { endKeepWarmTask(trip: trip) }
        guard awayClock.graceEnded(trip: trip), UIApplication.shared.applicationState == .background else { return }
        if kioskActive || starting { stopKiosk(leavingApp: true) }
        stopClientIfBackground()
    }

    /// Ends the background task `trip` took, once. A later trip's task is
    /// left alone, so an earlier trip's timer can't cut its time short.
    private func endKeepWarmTask(trip: Int) {
        guard trip == keepWarmTrip, keepWarmTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(keepWarmTask)
        keepWarmTask = .invalid
    }
}
#endif
