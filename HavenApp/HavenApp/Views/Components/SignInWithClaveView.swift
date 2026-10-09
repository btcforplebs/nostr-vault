import SwiftUI
import CoreImage
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Sign in with Clave
//
// One-tap pairing with a signer app, the iOS counterpart of Android's Amber
// login. On iPhone it opens Clave with a nostrconnect:// request; the user
// approves there and Clave sends them back. On the Mac there is no Clave, so
// it shows the request as a QR code to scan with Clave on the phone. Either
// way the app then waits for Clave's answer and hands the signer's pubkey to
// `onPaired`, which stores and connects it like a pasted bunker link.

struct SignInWithClaveView: View {
    /// Stores the pairing and connects; throws to show an error here.
    let onPaired: (NIP46Service.NostrConnectRequest, String) async throws -> Void

    private enum Phase: Equatable {
        case idle
        case waiting
        case connecting
    }

    @State private var phase: Phase = .idle
    @State private var request: NIP46Service.NostrConnectRequest?
    @State private var waitTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .idle:
                Button(action: start) {
                    Label(Self.startTitle, systemImage: "key.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(Self.startCaption)
                    .font(.appCaption)
                    .foregroundColor(.secondary)

            case .waiting:
                #if os(macOS)
                if let request, let image = Self.qrImage(for: request.uri) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .frame(maxWidth: .infinity)
                }
                #endif
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.waitingText)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    #if os(iOS)
                    Button("Open Clave again") { openClave() }
                    #else
                    Button("Copy link") { copyRequest() }
                    #endif
                    Spacer()
                    Button("Cancel", role: .cancel) { cancel() }
                }
                .buttonStyle(.borderless)

            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to Clave…")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.appCaption)
                    .foregroundColor(.red)
            }
        }
        .onDisappear { waitTask?.cancel() }
    }

    // MARK: - Copy

    #if os(iOS)
    private static let startTitle: LocalizedStringKey = "Sign in with Clave"
    private static let startCaption: LocalizedStringKey = "Opens Clave. Approve there and you'll come straight back."
    private static let waitingText: LocalizedStringKey = "Approve in Clave, then come back here."
    #else
    private static let startTitle: LocalizedStringKey = "Connect with Clave on your iPhone"
    private static let startCaption: LocalizedStringKey = "Shows a code to scan with Clave on your phone."
    private static let waitingText: LocalizedStringKey = "Scan this with Clave on your iPhone and approve."
    #endif

    // MARK: - Flow

    private func start() {
        errorMessage = nil
        #if os(iOS)
        let includeCallback = true
        #else
        let includeCallback = false
        #endif
        guard let request = NIP46Service.shared.makeNostrConnectRequest(includeCallback: includeCallback) else {
            errorMessage = String(localized: "Couldn't create a sign-in request. Try again.")
            return
        }
        self.request = request
        phase = .waiting
        #if os(iOS)
        openClave()
        #endif
        waitTask?.cancel()
        waitTask = Task { await wait(for: request) }
    }

    private func wait(for request: NIP46Service.NostrConnectRequest) async {
        do {
            let signerPubkey = try await NIP46Service.shared.awaitNostrConnect(request)
            phase = .connecting
            try await onPaired(request, signerPubkey)
            phase = .idle
        } catch is CancellationError {
            phase = .idle
        } catch NIP46Error.timeout {
            errorMessage = String(localized: "Clave didn't answer. Tap to try again.")
            phase = .idle
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    private func cancel() {
        waitTask?.cancel()
        waitTask = nil
        request = nil
        phase = .idle
    }

    #if os(iOS)
    /// Re-sends the same request: an answer already given is re-sent by Clave
    /// without asking again, so this is the fix for "I approved, nothing
    /// happened".
    private func openClave() {
        guard let request, let link = NIP46Service.claveLink(for: request) else { return }
        UIApplication.shared.open(link)
    }
    #else
    private func copyRequest() {
        guard let request else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.uri, forType: .string)
    }
    #endif

    private static func qrImage(for string: String) -> CGImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
