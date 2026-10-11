import SwiftUI

/// Deep space behind the globe.
struct GlobeSpace: View {
    static let edge = Color.black

    var body: some View {
        RadialGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Self.edge],
                       center: .center, startRadius: 40, endRadius: 900)
            .ignoresSafeArea()
    }
}
