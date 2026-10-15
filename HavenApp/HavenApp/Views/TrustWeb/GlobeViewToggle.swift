import SwiftUI

/// The WOT globe as a globe (3D) or laid flat as a disc (2D). Kept across
/// launches; the globe is the default.
enum GlobeViewSetting {
    static let flatKey = "wotGlobeFlat"
}

/// The bar's 3D / 2D switch, beside the Live arrivals antenna. It shows the
/// view you are in, and a tap swaps to the other.
struct GlobeViewToggle: View {
    @AppStorage(GlobeViewSetting.flatKey) private var flat = false

    var body: some View {
        IconFilterButton(icon: flat ? "view.2d" : "view.3d", tooltip: flat ? "Flat view" : "Globe view",
                         isSelected: false, color: .havenPurple) { flat.toggle() }
            .accessibilityLabel(Text("Globe or flat view"))
            .accessibilityValue(Text(flat ? "Flat, 2D" : "Globe, 3D"))
            .accessibilityHint(Text("Switches the Web of Trust between a globe and a flat map"))
    }
}
