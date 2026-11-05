import SwiftUI

/// The camera for a pairing code: the iPhone's QR scanner, or the Mac's
/// webcam. `validate` returns words to show over the camera and keep
/// scanning, or nil to take the code, which goes to `onCode`.
struct PairScanView: View {
    let title: String
    var validate: (String) -> String? = { _ in nil }
    let onCode: (String) -> Void

    var body: some View {
        #if os(iOS)
        QRScannerView(title: title, validate: validate, onCodeScanned: onCode)
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        #else
        MacWebcamScanner(title: title, validate: validate, onCode: onCode)
            .frame(height: 300)
        #endif
    }
}
