import SwiftUI

/// The one "you have news" dot: a red badge with a thin dark ring that cuts it
/// out of the icon it sits on, and a soft red glow, so it reads as a
/// notification and not as part of the glyph. It springs in when the news
/// arrives and fades out when it's seen.
///
/// Place it with `.overlay(alignment: .topTrailing) { NewsDot(isShown: …) }`.
/// It draws nothing while `isShown` is false, so the overlay can stay put.
struct NewsDot: View {
    let isShown: Bool
    /// The red part's diameter. The ring is drawn outside it.
    var size: CGFloat = 10
    var ring: CGFloat = 1.5
    var color: Color = NewsDot.red

    /// The system red, as a fixed color so the glow matches it.
    static let red = Color(red: 1, green: 0.23, blue: 0.19)

    var body: some View {
        ZStack {
            if isShown {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .padding(ring)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .shadow(color: color.opacity(0.7), radius: 3)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(Motion.pop, value: isShown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
