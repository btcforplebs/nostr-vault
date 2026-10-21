import SwiftUI

// MARK: - Connect Signer Sheet

struct ConnectSignerSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    let npub: String

    @State private var bunkerURI: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String? = nil
    #if os(iOS)
    @State private var showQRScanner = false
    #endif

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { performDismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Connect Remote Signer")
                    .font(.appHeadline)
                Spacer()
                Button("Connect") { connectBunker() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                    .disabled(bunkerURI.isEmpty || isConnecting)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                SignInWithClaveView { request, signerPubkey in
                    try await pairWithClave(request, signerPubkey: signerPubkey)
                }
                .tint(Color.havenPurple)

                Divider()

                Text("Paste the bunker:// URI from your remote signer app to connect it to this account.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)

                TextField("bunker://...", text: $bunkerURI)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.appCaption)
                        .foregroundColor(.red)
                }

                if isConnecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting...").font(.appCaption).foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(width: 420)
        #else
        NavigationStack {
            Form {
                Section {
                    SignInWithClaveView { request, signerPubkey in
                        try await pairWithClave(request, signerPubkey: signerPubkey)
                    }
                    .tint(Color.havenPurple)
                } footer: {
                    Text("Or paste a bunker link from any signer app below.")
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("bunker://...", text: $bunkerURI)
                            .textContentType(.URL)
                            .autocapitalization(.none)

                        Button(action: { showQRScanner = true }) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.appSystem(size: 20))
                                .foregroundColor(Color.havenPurple)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scan QR code")
                    }
                } header: {
                    Text("Bunker URI")
                } footer: {
                    Text("Paste or scan the bunker:// connection string from your remote signer app.")
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.appCaption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button(action: connectBunker) {
                        HStack {
                            Text("Connect")
                            if isConnecting {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(bunkerURI.isEmpty || isConnecting)
                    if isConnecting {
                        Text("Approve the connection in your signer app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Connect Signer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { performDismiss() }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(
                    title: "Scan your signer’s bunker code",
                    validate: { code in
                        BunkerURI.normalized(code) == nil
                            ? "That QR code is not a bunker:// connection string"
                            : nil
                    }
                ) { scannedCode in
                    showQRScanner = false
                    guard let uri = BunkerURI.normalized(scannedCode) else { return }
                    bunkerURI = uri
                    errorMessage = nil
                }
            }
        }
        #endif
    }

    /// Finishes a "Sign in with Clave" pairing for this account: stored like a
    /// pasted bunker link (with the pairing's own client key), then connected.
    private func pairWithClave(_ request: NIP46Service.NostrConnectRequest, signerPubkey: String) async throws {
        let bunkerConfig = AccountBunkerConfig(
            bunkerURI: NIP46Service.bunkerURI(signerPubkey: signerPubkey, relays: request.relays),
            signerPubkey: signerPubkey,
            relayURL: request.relays.first ?? "",
            secret: "",
            clientSecretKey: request.clientSecretKey,
            clientPubkey: request.clientPubkey
        )
        configService.setBunkerConfig(bunkerConfig, forNpub: npub)
        configService.setSigningMode("nip46", forNpub: npub)
        let activeNpub = configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub
        do {
            if npub == activeNpub {
                try await NIP46Service.shared.waitForConnection()
            }
        } catch {
            configService.removeBunkerConfig(forNpub: npub)
            throw error
        }
        performDismiss()
    }

    private func connectBunker() {
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let info = try NIP46Service.parseBunkerURI(bunkerURI)

                var bunkerConfig = AccountBunkerConfig(
                    bunkerURI: bunkerURI,
                    signerPubkey: info.signerPubkey,
                    relayURL: info.relayURL,
                    secret: info.secret
                )

                // Generate a client keypair for this account's connection
                if let keyPairCStr = GenerateKeyPairC() {
                    let keyPairStr = String(cString: keyPairCStr)
                    free(keyPairCStr)
                    let parts = keyPairStr.split(separator: ":")
                    if parts.count == 2 {
                        bunkerConfig.clientSecretKey = String(parts[0])
                        bunkerConfig.clientPubkey = String(parts[1])
                    }
                }

                configService.setBunkerConfig(bunkerConfig, forNpub: npub)
                // Set signing mode to nip46 for this account
                configService.setSigningMode("nip46", forNpub: npub)

                // If this is the active account, setSigningMode already started
                // the connect: wait on that one handshake rather than starting a
                // second that would re-send the single-use secret.
                let activeNpub = configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub
                if npub == activeNpub {
                    try await NIP46Service.shared.waitForConnection()
                }

                isConnecting = false
                performDismiss()
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
                configService.removeBunkerConfig(forNpub: npub)
            }
        }
    }

    private func performDismiss() {
        onDismiss?()
        dismiss()
    }
}
