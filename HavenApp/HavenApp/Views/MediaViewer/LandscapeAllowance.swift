import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Lets the phone turn sideways while a full-screen viewer is open, and turns
/// it upright again once the last one closes.
///
/// The clip page on screen holds a slot and gives it up when it is paged
/// away or the viewer starts to close (`LandscapeCount.pageHolds`); photos
/// never hold one. A landscape clip turns the screen
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

    /// `immediately` is for a viewer that is closing: it turns upright as
    /// the close starts, so the zoom back into the post is not drawn sideways.
    static func close(immediately: Bool = false) {
        #if os(iOS)
        guard isPhone, count.closed() else { return }
        if immediately {
            turn(to: .portrait)
            return
        }
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
        guard isPhone else { return }
        // The clip's own view can appear a moment before the viewer around it
        // opens its slot, so the slot is checked after the read, not before.
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
    /// Holds a landscape slot while `held` is true (`LandscapeCount.pageHolds`).
    /// Letting go while `closing` turns the phone upright at once.
    func landscapeSlot(held: Bool, closing: Bool = false) -> some View {
        modifier(LandscapeSlot(held: held, closing: closing))
    }

    /// Turns the screen sideways once a wide clip at `url` is showing.
    func turnsSidewaysForWideClip(_ url: URL?) -> some View {
        task(id: url) {
            guard let url else { return }
            await LandscapeAllowance.turnSidewaysIfWide(url)
        }
    }
}

private struct LandscapeSlot: ViewModifier {
    let held: Bool
    let closing: Bool
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear { sync(held) }
            .onChange(of: held) { _, now in sync(now) }
            .onDisappear { sync(false) }
    }

    private func sync(_ want: Bool) {
        guard want != holding else { return }
        holding = want
        if want {
            LandscapeAllowance.open()
        } else {
            LandscapeAllowance.close(immediately: closing)
        }
    }
}
