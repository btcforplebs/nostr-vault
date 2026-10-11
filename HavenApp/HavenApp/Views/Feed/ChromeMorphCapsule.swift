import SwiftUI

/// The feed top bar's glass pill. With the fold it narrows from its content's
/// full width to a circle on `alignment`'s edge, the same morph the bottom
/// tab bar makes.
///
/// Only the glass and the clip move. The content keeps its layout, so the
/// navigation bar hosting it never relayouts mid-drag. The system's own
/// toolbar glass must be hidden (`hidingSharedToolbarBackground()`): UIKit
/// animates that platter on its own clock and leaves it behind.
struct ChromeMorphCapsule<Content: View>: View {
    var alignment: Alignment
    var isEnabled = true
    @ViewBuilder var content: Content

    @State private var size: CGSize = .zero

    var body: some View {
        let p = isEnabled ? ChromeCollapse.shared.progress : 0
        // Unmeasured on the first pass: draw at the content's own size.
        let width: CGFloat? = size == .zero ? nil : size.width + (size.height - size.width) * p
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .mask(alignment: alignment) { Capsule().frame(width: width) }
            // Taps land only inside the glass: folded, the empty bar where
            // the pill's content used to be does not open it.
            .contentShape(AlignedCapsule(width: width, alignment: alignment))
            .background(alignment: alignment) {
                Color.clear
                    .frame(width: width)
                    .applyGlassCapsule()
            }
    }
}

/// A capsule `width` wide, pinned to `alignment`'s edge of its rect.
private struct AlignedCapsule: Shape {
    var width: CGFloat?
    var alignment: Alignment

    func path(in rect: CGRect) -> Path {
        let w = min(width ?? rect.width, rect.width)
        let x: CGFloat
        switch alignment.horizontal {
        case .leading: x = rect.minX
        case .trailing: x = rect.maxX - w
        default: x = rect.midX - w / 2
        }
        return Capsule().path(in: CGRect(x: x, y: rect.minY, width: w, height: rect.height))
    }
}
