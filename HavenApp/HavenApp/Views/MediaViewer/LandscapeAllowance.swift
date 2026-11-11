import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Lets the phone turn sideways while a full-screen viewer is open, and turns
/// it upright again once the last one closes.
///
/// Every viewer that can show video opens a slot on the way in and closes it
/// on the way out (`LandscapeCount`). A landscape clip turns the screen
/// sideways by itself (Logen, 2026-11-11: "auto-turn go"). iPad and Mac are
/// left alone: they are never held upright.
@MainActor
enum LandscapeAllowance {
    private static var count = LandscapeCount()

    static var isAllowed: Bool { count.allowsLandscape }

    static func open() {
        #if os(iOS)
        guard isPhone else { return }
        let wasAllowed = count.allowsLandscape
        count.opened()
        if !wasAllowed { refreshAllowedOrientations() }
        #endif
    }

    static func close() {
        #if os(iOS)
        guard isPhone, count.closed() else { return }
        // Swiping between pages can close one page before the next opens.
        // Wait a turn of the run loop, so that does not snap the phone upright.
        DispatchQueue.main.async {
            guard !count.allowsLandscape else { return }
            turn(to: .portrait)
        }
        #endif
    }

    /// Turns the screen sideways while a viewer is open.
    static func turnSideways() {
        #if os(iOS)
        guard isPhone, count.allowsLandscape else { return }
        turn(to: .landscapeRight)
        #endif
    }

    /// Turns the screen sideways when the clip at `url` is wider than tall.
    /// Reads only the clip's header; a clip that cannot be read stays upright.
    static func turnSidewaysIfWide(_ url: URL) async {
        #if os(iOS)
        guard isPhone, count.allowsLandscape else { return }
        guard let size = await displaySize(ofVideoAt: url),
              LandscapeCount.turnsSideways(size),
              !Task.isCancelled else { return }
        turnSideways()
        #endif
    }

    /// The clip's shape as shown: `naturalSize` is before rotation, so a
    /// phone-shot portrait clip would read as landscape without the transform.
    nonisolated static func displaySize(ofVideoAt url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let oriented = natural.applying(transform)
        return CGSize(width: abs(oriented.width), height: abs(oriented.height))
    }

    #if os(iOS)
    private static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// UIKit reads the allowed orientations again only when told to, from
    /// every controller up to the sheet on top; until then a request for
    /// landscape is refused against the old, upright-only answer.
    private static func refreshAllowedOrientations() {
        guard let scene = windowScene else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
    }

    private static func turn(to orientations: UIInterfaceOrientationMask) {
        refreshAllowedOrientations()
        windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            #if DEBUG
            print("LandscapeAllowance: orientation refused: \(error)")
            #endif
        }
    }

    private static var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
    }
    #endif
}

extension View {
    /// Holds a landscape slot for as long as this full-screen viewer shows.
    func allowsLandscapeWhileShown() -> some View {
        onAppear { LandscapeAllowance.open() }
            .onDisappear { LandscapeAllowance.close() }
    }

    /// Turns the screen sideways once a wide clip at `url` is showing.
    func turnsSidewaysForWideClip(_ url: URL?) -> some View {
        task(id: url) {
            guard let url else { return }
            await LandscapeAllowance.turnSidewaysIfWide(url)
        }
    }
}
