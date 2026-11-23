import CoreImage
import Foundation

/// Draws a sign-in request as a QR code for a signer on another device.
enum NostrConnectQR {
    /// Black modules on white, `scale` pixels per module. nil when the text
    /// is too long for a QR code.
    static func cgImage(for string: String, scale: CGFloat = 8) -> CGImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
