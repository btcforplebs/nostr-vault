import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Runs Auto-Mirror (`HavenConfig.autoMirrorMedia`) when the app opens or
/// comes back to the front, once the vault is serving, not only when the
/// Media tab is opened. `AutoMirrorSchedule` keeps it to once every few
/// hours. Files it brings in show on the Media tab as they land
/// (`BlossomService.announceStoredInVault`). Android twin: the same start
/// from the app's launch, not the Media screen.
@MainActor
enum AutoMirrorOnOpen {
    private static var observers: Set<AnyCancellable> = []

    /// Call once at launch.
    static func start() {
        guard observers.isEmpty else { return }
        let relay = RelayProcessManager.shared
        // The vault coming up (launch, or a restart) …
        relay.$isRunning.combineLatest(relay.$isBooting)
            .map { running, booting in running && !booting }
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { _ in runIfDue() }
            .store(in: &observers)
        // … and the app coming back to the front.
        #if canImport(UIKit)
        let foreground = UIApplication.willEnterForegroundNotification
        #else
        let foreground = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: foreground)
            .receive(on: DispatchQueue.main)
            .sink { _ in runIfDue() }
            .store(in: &observers)
    }

    static func runIfDue() {
        let config = ConfigService.shared
        let relay = RelayProcessManager.shared
        guard relay.isRunning, !relay.isBooting else { return }
        guard AutoMirrorSchedule.isDue(enabled: config.config.autoMirrorMedia,
                                       lastRun: VaultHistory.lastMediaImport,
                                       now: Date()) else { return }
        MirrorService.shared.runMirror(configService: config, nostrService: .shared)
    }
}
