import SwiftUI

// The "I use Nostr" path (iPhone/iPad): one key field, then the import tour.
// Design: ~/.buzz/OUTBOX/i-use-nostr-mockup.html (Tory, 2026-10-07).

// MARK: - Your key

/// One field for whatever the person already has. What they paste decides
/// the mode (`IdentityInput`): an npub or name@domain is read-only, a private
/// key or a signer app can post. Replaces the Full Setup / Browse choice.
struct UseNostrKeyStep: View {
    @Binding var npub: String
    @Binding var nsec: String
    @Binding var nsecPassword: String
    @Binding var signingMode: String
    @Binding var bunkerURI: String
    let onContinue: () -> Void

    @State private var input = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var showingScanner = false
    @State private var showingSigner = false
    @State private var signerConnected = false
    @State private var appeared = false

    private var kind: IdentityInput { IdentityInput(input) }

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            Text("Who are you on Nostr?")
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)

            Text("Paste your public key or name@domain to read. Add your private key to post too.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            keyField

            if let line = modeLine {
                modeCard(line)
            }

            if needsPassword {
                passwordField
            }

            if signerConnected == false && !kind.canPost {
                signerSection
            }

            if let errorText {
                Text(errorText)
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.error)
                    .multilineTextAlignment(.center)
            }

            WizardPrimaryButton(
                title: isWorking ? "Checking…" : String(localized: "setup.action.continue"),
                action: handleContinue,
                disabled: !canContinue || isWorking
            )

            Text("Your private key stays on this device. It's never sent anywhere.")
                .font(.appSystem(size: 12))
                .foregroundColor(WizardColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .opacity(appeared ? 1 : 0)
        .animation(WizardAnimations.fadeIn, value: appeared)
        .onAppear { appeared = true }
        .onChange(of: input) { _, _ in
            errorText = nil
            password = ""
        }
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            QRScannerView(title: "Scan your key or signer link") { code in
                showingScanner = false
                input = code
            }
        }
        #endif
    }

    // MARK: Field

    private var keyField: some View {
        HStack(spacing: 8) {
            TextField("npub, name@domain, nsec or bunker://", text: $input)
                .textFieldStyle(.plain)
                .font(.appSystem(size: 15, design: .monospaced))
                .foregroundColor(WizardColors.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .accessibilityLabel("Your key or name")
                // The keyboard covers Continue on a phone; Return does the same.
                .submitLabel(.continue)
                .onSubmit { if canContinue && !isWorking { handleContinue() } }
            #if os(iOS)
            Button { showingScanner = true } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.appSystem(size: 20))
                    .foregroundColor(WizardColors.accentPrimary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan a QR code")
            #endif
        }
        .padding(14)
        .background(WizardColors.bgCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isUsable ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: isUsable ? 2 : 1)
        )
    }

    private struct ModeLine {
        enum Tone { case read, post, error }
        let tone: Tone
        let title: String
        let detail: String
    }

    /// What the pasted thing means, in one line. Shape first (`IdentityInput`),
    /// then the checksum, so a cut-off key says so before Continue.
    private var modeLine: ModeLine? {
        if signerConnected {
            return ModeLine(tone: .post, title: "Signer connected · you can post",
                            detail: "Your signer app approves each post. Your key never touches Nostr Vault.")
        }
        switch kind {
        case .empty: return nil
        case .publicKey, .secretKey:
            guard keyChecksumOK else {
                return ModeLine(tone: .error, title: "That doesn't look complete",
                                detail: "Check that you copied the whole key. npub and nsec keys are 63 characters.")
            }
        default: break
        }
        switch kind {
        case .publicKey:
            return ModeLine(tone: .read, title: "Read-only",
                            detail: "You can see your feed, notes and follows. Add your private key later in Settings to post.")
        case .nip05(let name):
            return ModeLine(tone: .read, title: "\(name) · read-only",
                            detail: "We'll look this up when you continue. Add your private key later in Settings to post.")
        case .secretKey:
            return ModeLine(tone: .post, title: "You can post",
                            detail: "Post, reply, DM and zap. Your key is saved encrypted on this device.")
        case .encryptedSecretKey:
            return ModeLine(tone: .post, title: "Encrypted key · you can post",
                            detail: "Enter the password you locked it with.")
        case .remoteSigner:
            return ModeLine(tone: .post, title: "Signer link · you can post",
                            detail: "Continue connects to your signer app. It approves each post.")
        case .hexKey, .unrecognised:
            return ModeLine(tone: .error, title: "That doesn't look right", detail: kind.hint ?? "")
        case .empty:
            return nil
        }
    }

    private func modeCard(_ line: ModeLine) -> some View {
        let color: Color = switch line.tone {
        case .read: WizardColors.textSecondary
        case .post: WizardColors.success
        case .error: WizardColors.error
        }
        let icon = switch line.tone {
        case .read: "eye"
        case .post: "checkmark.circle.fill"
        case .error: "exclamationmark.circle"
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.title)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                Text(line.detail)
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(WizardColors.bgCard)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Password

    private var needsPassword: Bool {
        switch kind {
        case .secretKey: return keyChecksumOK
        case .encryptedSecretKey: return true
        default: return false
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isEncrypted
                 ? "Password for this key"
                 : "Choose a password to lock your key on this device")
                .font(.appSystem(size: 13))
                .foregroundColor(WizardColors.textSecondary)
            SecureField("Password", text: $password)
                .submitLabel(.continue)
                .onSubmit { if canContinue && !isWorking { handleContinue() } }
                .textFieldStyle(.plain)
                .foregroundColor(WizardColors.textPrimary)
                .padding(12)
                .background(WizardColors.bgCard)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(WizardColors.borderSubtle, lineWidth: 1))
        }
    }

    private var isEncrypted: Bool {
        if case .encryptedSecretKey = kind { return true }
        return false
    }

    // MARK: Signer

    @ViewBuilder
    private var signerSection: some View {
        if showingSigner {
            VStack(spacing: 8) {
                SignInWithClaveView { request, signerPubkey in
                    try await pairSigner(request, signerPubkey: signerPubkey)
                }
                .tint(WizardColors.accentPrimary)
                Text("Or paste a bunker:// link from any signer app above.")
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
        } else {
            HStack {
                Rectangle().fill(WizardColors.borderSubtle).frame(height: 1)
                Text("or").font(.appSystem(size: 12)).foregroundColor(WizardColors.textMuted)
                Rectangle().fill(WizardColors.borderSubtle).frame(height: 1)
            }
            Button { showingSigner = true } label: {
                Label("Use a signer app", systemImage: "key.horizontal.fill")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(WizardColors.bgElevated)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Validation

    /// A one-character typo is a different, valid-looking key, so check it.
    private var keyChecksumOK: Bool {
        switch kind {
        case .publicKey(let key):
            guard Bech32.hasValidChecksum(key), let d = Bech32.decode(key) else { return false }
            return d.hrp == "npub" && d.data.count == 32
        case .secretKey(let key):
            return derivedNpub(fromNsec: key) != nil && Bech32.hasValidChecksum(key)
        default:
            return true
        }
    }

    private var isUsable: Bool {
        guard let line = modeLine else { return false }
        return line.tone != .error
    }

    private var canContinue: Bool {
        if signerConnected { return true }
        guard isUsable else { return false }
        if needsPassword { return !password.isEmpty }
        return true
    }

    private func handleContinue() {
        if signerConnected { onContinue(); return }
        switch kind {
        case .publicKey(let key):
            npub = key
            nsec = ""
            signingMode = "local"
            onContinue()
        case .nip05(let name):
            resolve(name)
        case .secretKey(let key):
            guard let derived = derivedNpub(fromNsec: key) else { return }
            npub = derived
            nsec = key
            nsecPassword = password
            signingMode = "local"
            onContinue()
        case .encryptedSecretKey(let key):
            do {
                let plain = try NIP49Service.decrypt(ncryptsec: key, password: password)
                guard let derived = derivedNpub(fromNsec: plain) else {
                    errorText = "That key didn't unlock. Check the password."
                    return
                }
                npub = derived
                nsec = plain
                nsecPassword = password
                signingMode = "local"
                onContinue()
            } catch {
                errorText = "That password didn't unlock the key."
            }
        case .remoteSigner:
            connectBunker(input.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            break
        }
    }

    private func derivedNpub(fromNsec value: String) -> String? {
        guard let decoded = Bech32.decode(value), decoded.hrp == "nsec", decoded.data.count == 32,
              let pkCStr = GetPublicKeyC(UnsafeMutablePointer(mutating: (decoded.hexString as NSString).utf8String)) else { return nil }
        let pk = String(cString: pkCStr)
        free(pkCStr)
        guard let pubData = Bech32.hexToData(pk) else { return nil }
        return Bech32.encode(hrp: "npub", data: pubData)
    }

    // MARK: Network

    /// NIP-05: https://domain/.well-known/nostr.json?name=user
    private func resolve(_ name: String) {
        let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
        let user = parts.count == 2 ? parts[0] : "_"
        let domain = parts.count == 2 ? parts[1] : name
        guard let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(user)") else {
            errorText = "That name@domain doesn't look right."
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let names = json["names"] as? [String: String],
                      let hex = names[user], hex.count == 64, hex.allSatisfy(\.isHexDigit),
                      let pubData = Bech32.hexToData(hex),
                      let found = Bech32.encode(hrp: "npub", data: pubData) else {
                    errorText = "Couldn't find \(name). Check the spelling, or paste your npub."
                    return
                }
                npub = found
                nsec = ""
                signingMode = "local"
                onContinue()
            } catch {
                errorText = "Couldn't reach \(domain). Check your connection, or paste your npub."
            }
        }
    }

    /// Same storage as the full-setup bunker field (`testBunkerConnection`).
    private func connectBunker(_ uri: String) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let info = try NIP46Service.parseBunkerURI(uri)
                let config = ConfigService.shared
                config.config.nip46SignerPubkey = info.signerPubkey
                config.config.nip46RelayURL = info.relayURL
                config.config.nip46Secret = info.secret
                config.config.nip46BunkerURI = uri
                config.config.signingMode = "nip46"
                config.save()
                let pubkey = try await NIP46Service.shared.connect(adoptSignerAccount: true)
                adoptSigner(pubkey: pubkey, uri: uri)
                onContinue()
            } catch {
                ConfigService.shared.config.signingMode = "local"
                errorText = "Couldn't connect to the signer: \(error.localizedDescription)"
            }
        }
    }

    /// Same storage as full setup's "Sign in with Clave".
    private func pairSigner(_ request: NIP46Service.NostrConnectRequest, signerPubkey: String) async throws {
        let uri = NIP46Service.bunkerURI(signerPubkey: signerPubkey, relays: request.relays)
        let config = ConfigService.shared
        config.config.nip46SignerPubkey = signerPubkey
        config.config.nip46RelayURL = request.relays.first ?? ""
        config.config.nip46Secret = ""
        config.config.nip46BunkerURI = uri
        config.config.nip46ClientSecretKey = request.clientSecretKey
        config.config.nip46ClientPubkey = request.clientPubkey
        config.config.signingMode = "nip46"
        config.save()
        do {
            let pubkey = try await NIP46Service.shared.connect(adoptSignerAccount: true)
            adoptSigner(pubkey: pubkey, uri: uri)
            signerConnected = true
        } catch {
            config.config.signingMode = "local"
            throw error
        }
    }

    private func adoptSigner(pubkey: String, uri: String) {
        if let pubData = Bech32.hexToData(pubkey),
           let signerNpub = Bech32.encode(hrp: "npub", data: pubData) {
            npub = signerNpub
        }
        nsec = ""
        bunkerURI = uri
        signingMode = "nip46"
    }
}
