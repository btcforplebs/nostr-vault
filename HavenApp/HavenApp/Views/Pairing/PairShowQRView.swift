import SwiftUI

/// A pairing code on screen for the other device to scan, with what to do
/// and how long it stays good.
struct PairShowQRView: View {
    let qr: String
    let caption: String
    let secondsLeft: Int?

    var body: some View {
        VStack(spacing: 14) {
            if let cg = MeshQRCode.cgImage(for: qr) {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Pairing code")
            }
            PairCodeText(code: qr)
            Text(caption)
                .font(.appBody)
                .multilineTextAlignment(.center)
            if let secondsLeft {
                Text("Good for \(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))")
                    .font(.appCaption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The 4 check words and the other device's short address (contract §5).
struct PairCheckWordsView: View {
    let words: [String]
    let short: String
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            Text(caption)
                .font(.appCaption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text(words.joined(separator: "  "))
                .font(.appSystem(size: 20, weight: .semibold, design: .monospaced))
                .accessibilityLabel("Check words: \(words.joined(separator: ", "))")
            Text(short)
                .font(.appSystem(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The code under the QR as text, with Copy, for pasting on the other device.
struct PairCodeText: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 6) {
            Text(code)
                .font(.appSystem(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                PlatformClipboard.copy(code)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .tint(.havenPurple)
        }
        .onChange(of: code) { _, _ in copied = false }
    }
}
