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
