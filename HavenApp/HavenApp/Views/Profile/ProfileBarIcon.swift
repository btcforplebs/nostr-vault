import SwiftUI

/// A bar icon that sits over the profile banner. It draws its own opaque
/// disc in the page color, so a bright or busy banner can't wash it out the
/// way the system's see-through glass did. Pair with
/// `hidingSharedToolbarBackground()` so iOS 26 doesn't add glass around it.
struct ProfileBarIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.appSystem(size: 16, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.platformWindowBackground))
            .overlay(Circle().stroke(Color.platformSeparator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .contentShape(Circle())
    }
}
