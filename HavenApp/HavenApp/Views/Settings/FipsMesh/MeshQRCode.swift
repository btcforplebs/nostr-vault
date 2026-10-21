import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// A mesh address as a QR code, for another device to scan.
enum MeshQRCode {
    static func cgImage(for string: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// The code at a fixed size, crisp at any scale.
    static func view(for string: String, label: String) -> some View {
        Group {
            if let cg = cgImage(for: string) {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(label)
            }
        }
    }
}
