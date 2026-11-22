import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The spare copy of a new key (setup screens r3, "Keep a spare"): a
/// paper card, or the key copied. Nothing here writes the key to disk: the
/// card is drawn in memory and handed to the system print panel.
/// Save to Passwords needs an associated domain the app doesn't have yet;
/// it is a follow-up if Logen OKs it (Tod 2026-11-22).
enum KeySpare {
    /// Opens the system print panel with the paper card. The completion
    /// says whether the job was sent (on iOS: reached the printer, not that
    /// paper came out). The panel's own Share/PDF buttons can still save the
    /// card; the step's text asks for paper only.
    @MainActor
    static func printCard(name: String, npub: String, nsec: String, completion: @escaping (Bool) -> Void) {
        let renderer = ImageRenderer(content: PaperKeyCard(name: name, npub: npub, nsec: nsec))
        renderer.scale = 3
        #if os(iOS)
        guard let image = renderer.uiImage else { return completion(false) }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = "Nostr key card"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = image
        let done: UIPrintInteractionController.CompletionHandler = { _, completed, _ in
            controller.printingItem = nil
            completion(completed)
        }
        // iPad shows the panel as a popover, which needs an anchor (Tron #2416).
        if UIDevice.current.userInterfaceIdiom == .pad,
           let window = UIApplication.shared.connectedScenes
               .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            let anchor = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            controller.present(from: anchor, in: window, animated: true, completionHandler: done)
        } else {
            controller.present(animated: true, completionHandler: done)
        }
        #elseif os(macOS)
        guard let image = renderer.nsImage else { return completion(false) }
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        let operation = NSPrintOperation(view: view)
        operation.jobTitle = "Nostr key card"
        completion(operation.run())
        #endif
    }
}

/// The printed spare: black on white, a QR of the secret key and the key in
/// full, so either can be typed or scanned back in.
struct PaperKeyCard: View {
    let name: String
    let npub: String
    let nsec: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("NOSTR VAULT · SECRET KEY")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.5)
                Spacer()
                Text("KEEP SAFE")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black, lineWidth: 1.5))
            }
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(name).font(.system(size: 22, weight: .bold))
            }
            HStack(alignment: .top, spacing: 16) {
                if let qr = MeshQRCode.cgImage(for: nsec) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Secret key").font(.system(size: 11, weight: .bold))
                    Text(nsec).font(.system(size: 11, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Public key").font(.system(size: 11, weight: .bold)).padding(.top, 4)
                    Text(npub).font(.system(size: 9, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Anyone with this card can post as you. Nobody can recover the key for you. Store it like a passport.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(.black)
        .padding(22)
        .frame(width: 480)
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black, lineWidth: 2).padding(4))
    }
}
