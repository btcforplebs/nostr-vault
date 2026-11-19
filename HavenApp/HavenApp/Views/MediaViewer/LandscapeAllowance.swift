import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Lets the phone turn sideways while a full-screen viewer is open, and turns
/// it upright again once the last one closes.
///
/// The clip page on screen holds a slot and gives it up when it is paged
/// away or the viewer starts to close (`LandscapeCount.pageHolds`); photos
/// never hold one. The screen turns only when you turn the phone (Logen,
/// 2026-11-19: no auto-turn for wide clips, replacing the 11-11 one) or tap
/// Live's Full screen. iPad and Mac are left alone: they are never held
/// upright.
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
