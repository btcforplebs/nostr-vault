import SwiftUI

extension ToolbarContent {
    /// Drops the Liquid Glass platter iOS 26 draws behind toolbar items, for
    /// items that draw their own glass.
    @ToolbarContentBuilder
    func hidingSharedToolbarBackground() -> some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension View {
    /// Turns off the top scroll-edge effect the system bar draws under its
    /// items (iOS 26+). The feed's pills have their own glass.
    @ViewBuilder
    func hidingTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
