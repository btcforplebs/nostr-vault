import SwiftUI
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
//
// iPhone/iPad also offer "Show a code for another device": the same request,
// without the come-back callback, as a QR for a signer on another phone
// (Amber on Android, Clave on a second iPhone) — like web's sign-in QR.

struct SignInWithClaveView: View {
    /// Stores the pairing and connects; throws to show an error here.
    let onPaired: (NIP46Service.NostrConnectRequest, String) async throws -> Void

    private enum Phase: Equatable {
        case idle
        case waiting
        case connecting
    }

    /// Where the signer is: this phone (open Clave) or another device (QR).
    private enum Target: Equatable {
        case thisDevice
        case otherDevice
    }

    @State private var phase: Phase = .idle
    #if os(iOS)
    @State private var target: Target = .thisDevice
    #else
    @State private var target: Target = .otherDevice
    #endif
    @State private var request: NIP46Service.NostrConnectRequest?
    @State private var waitTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .idle:
                Button { start(.thisDevice) } label: {
                    Label(Self.startTitle, systemImage: "key.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(Self.startCaption)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                #if os(iOS)
                Button { start(.otherDevice) } label: {
                    Label("Show a code for another device", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("showNostrConnectQR")
                Text("Scan it with a signer app on another phone, like Amber or Clave.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                #endif

            case .waiting:
                if target == .otherDevice, let request {
                    NostrConnectQRCard(uri: request.uri)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(target == .otherDevice ? Self.qrWaitingText : Self.waitingText)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    if target == .thisDevice {
                        Button("Open Clave again") { openClave() }
                    } else {
                        Button("Copy link") { copyRequest() }
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { cancel() }
                }
                .buttonStyle(.borderless)

            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(target == .otherDevice ? "Connecting to your signer…" : "Connecting to Clave…")
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
    private static let qrWaitingText: LocalizedStringKey = "Scan this with the signer app on your other device, then approve there."
    #else
    private static let startTitle: LocalizedStringKey = "Connect with Clave on your iPhone"
    private static let startCaption: LocalizedStringKey = "Shows a code to scan with Clave on your phone."
    private static let waitingText: LocalizedStringKey = "Scan this with Clave on your iPhone and approve."
    private static let qrWaitingText: LocalizedStringKey = waitingText
    #endif

    // MARK: - Flow

    private func start(_ target: Target) {
        errorMessage = nil
        #if os(iOS)
        // Only Clave on THIS phone can send us back; a signer on another
        // device must not be told to open nostrvault:// there.
        let includeCallback = target == .thisDevice
        #else
        let includeCallback = false
        #endif
        self.target = target
        guard let request = NIP46Service.shared.makeNostrConnectRequest(includeCallback: includeCallback) else {
            errorMessage = String(localized: "Couldn't create a sign-in request. Try again.")
            return
        }
        self.request = request
        phase = .waiting
        #if os(iOS)
        if target == .thisDevice { openClave() }
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
            errorMessage = target == .otherDevice
                ? String(localized: "The signer didn't answer. Try again.")
                : String(localized: "Clave didn't answer. Tap to try again.")
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
    private func openClave() {}
    #endif

    private func copyRequest() {
        guard let request else { return }
        #if os(iOS)
        UIPasteboard.general.string = request.uri
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.uri, forType: .string)
        #endif
    }
}
