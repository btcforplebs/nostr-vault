import SwiftUI

/// A nostrconnect:// sign-in request drawn as a QR code for a signer app on
/// another device (Amber, Clave, nsec.app…). White tile with a quiet zone so
/// a camera reads it in dark mode too.
struct NostrConnectQRCard: View {
    let uri: String
    var size: CGFloat = 220

    var body: some View {
        if let image = NostrConnectQR.cgImage(for: uri) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel(Text("Sign-in code for a signer app"))
                .accessibilityIdentifier("nostrConnectQR")
        }
    }
}
