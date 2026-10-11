import SwiftUI

extension View {
    /// With the system toolbar glass hidden, iOS 26 switches the scroll edge
    /// under the top bar to its hard style: a dark band with a cut edge.
    /// Keep the soft fade the bar had with the system glass.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
