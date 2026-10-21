import SwiftUI

// MARK: - Step 2: Identity

struct IdentityStepView: View {
    let isBrowseMode: Bool
    @Binding var npub: String
    @Binding var nsec: String
    @Binding var nsecPassword: String
    @Binding var signingMode: String
    @Binding var bunkerURI: String
    @Binding var bunkerConnected: Bool
    let onContinue: () -> Void

    enum SigningMethod { case local, nip46 }

    @State private var appeared = false
    @State private var generatedKeys = false
    @State private var isConnectingBunker = false
    @State private var bunkerError: String?
    @State private var selectedMethod: SigningMethod = .local
    // Browse mode: NIP-05 + QR
    @State private var identityInput: String = ""
    @State private var isResolvingNIP05 = false
    @State private var nip05Error: String?
    @State private var resolvedFromNIP05: String? = nil
    @State private var activeScanner: ScanTarget?

    /// Which field a scanned QR code should fill.
    private enum ScanTarget: String, Identifiable {
        case identity, bunker
        var id: String { rawValue }
    }

    private var isNpubValid: Bool {
        guard !npub.isEmpty, npub.hasPrefix("npub") else { return false }
        // decode skips the checksum: without it a one-character typo is a
        // different, valid-looking key that setup would save as the owner.
        guard Bech32.hasValidChecksum(npub),
              let decoded = Bech32.decode(npub), decoded.hrp == "npub", decoded.data.count == 32 else { return false }
        return true
    }

    /// Checks if browse mode input looks like a NIP-05 identifier (user@domain or just domain.tld)
    private var looksLikeNIP05: Bool {
        let trimmed = identityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.contains("@") && trimmed.contains(".") { return true }
        // bare domain: "domain.com" — must have a dot and no spaces
        if !trimmed.contains(" ") && !trimmed.hasPrefix("npub") && !trimmed.hasPrefix("nprofile") && trimmed.contains(".") { return true }
        return false
    }

    private var canContinue: Bool {
        if isBrowseMode {
            if isResolvingNIP05 { return false }
            if isNpubValid { return true }
            if looksLikeNIP05 { return true }
            return false
        }
        guard isNpubValid else { return false }
        if selectedMethod == .nip46 { return bunkerConnected }
        if !nsec.isEmpty {
            // The key decides the identity: an nsec whose npub isn't the one
            // in the field would sign as someone other than the owner.
            guard derivedNpub == npub, !nsecPassword.isEmpty else { return false }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(isBrowseMode ? String(localized: "setup.identity.title.browse") : String(localized: "setup.identity.title.full"))
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            if isBrowseMode {
                Text(isIOSDevice ? "Enter your npub, NIP-05 (user@domain), or scan a QR code." : "Enter your npub or NIP-05 (user@domain).")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)
            }

            if isBrowseMode {
                // Browse mode: unified identity input (npub / NIP-05 / QR)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Identity")
                        .font(.appSystem(size: 13))
                        .foregroundColor(WizardColors.textSecondary)

                    HStack(spacing: 8) {
                        TextField("npub1... or user@domain.com", text: $identityInput)
                            .textFieldStyle(.plain)
                            .font(.appSystem(size: 15))
                            .foregroundColor(WizardColors.textPrimary)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            #endif
                            .onChange(of: identityInput) { _, newValue in
                                nip05Error = nil
                                resolvedFromNIP05 = nil
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                // Strip nostr: prefix
                                let cleaned = trimmed.hasPrefix("nostr:") ? String(trimmed.dropFirst(6)) : trimmed
                                if cleaned.hasPrefix("npub1") {
                                    if let decoded = Bech32.decode(cleaned), decoded.hrp == "npub" {
                                        npub = cleaned
                                    } else {
                                        npub = ""
                                    }
                                } else if cleaned.hasPrefix("nprofile1") {
                                    // The same decoder the feed's mention links use.
                                    if let pubkeyHex = QuoteReference.profilePubkey(fromBech32: cleaned),
                                       let pubData = Bech32.hexToData(pubkeyHex),
                                       let resolvedNpub = Bech32.encode(hrp: "npub", data: pubData) {
                                        npub = resolvedNpub
                                    } else {
                                        npub = ""
                                    }
                                } else {
                                    npub = ""
                                }
                            }

                        #if os(iOS)
                        Button(action: { activeScanner = .identity }) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.appSystem(size: 20))
                                .foregroundColor(WizardColors.accentPrimary)
                                .frame(width: 36, height: 36)
                                .background(WizardColors.bgElevated)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                    .padding(12)
                    .background(WizardColors.bgCard)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(WizardColors.borderSubtle, lineWidth: 1)
                    )
                }
                .opacity(appeared ? 1 : 0)
                .offset(x: appeared ? 0 : 20)
                .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

                // Status indicators for browse mode
                if isResolvingNIP05 {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(WizardColors.accentPrimary)
                        Text("Resolving NIP-05...")
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                    }
                } else if let resolved = resolvedFromNIP05 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(WizardColors.success)
                        Text("Resolved: \(String(resolved.prefix(20)))...")
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.success)
                    }
                } else if let error = nip05Error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text(error)
                            .font(.appSystem(size: 13))
                    }
                    .foregroundColor(WizardColors.error)
                } else if !identityInput.isEmpty && !isNpubValid && !looksLikeNIP05 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text("Enter a valid npub or NIP-05 identifier")
                            .font(.appSystem(size: 13))
                    }
                    .foregroundColor(WizardColors.error)
                } else if isNpubValid && !identityInput.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(WizardColors.success)
                        Text("Valid public key")
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.success)
                    }
                }
            } else {
                // Full mode: standard npub field
                WizardInputField(label: String(localized: "setup.identity.label.npub"), text: $npub, placeholder: "npub1...", isDisabled: (selectedMethod == .nip46 && bunkerConnected) || (selectedMethod == .local && derivedNpub != nil))
                    .opacity(appeared ? 1 : 0)
                    .offset(x: appeared ? 0 : 20)
                    .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

                if !npub.isEmpty && !isNpubValid {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text(String(localized: "setup.identity.invalidNpub"))
                            .font(.appSystem(size: 13))
                    }
                    .foregroundColor(WizardColors.error)
                }
            }

            if !isBrowseMode {
                // Signing method selector cards
                HStack(spacing: 12) {
                    signingMethodCard(
                        method: .local,
                        icon: "key.fill",
                        title: String(localized: "setup.identity.method.local.title"),
                        subtitle: String(localized: "setup.identity.method.local.subtitle")
                    )
                    signingMethodCard(
                        method: .nip46,
                        icon: "link.badge.plus",
                        title: String(localized: "setup.identity.method.remote.title"),
                        subtitle: String(localized: "setup.identity.method.remote.subtitle")
                    )
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.28), value: appeared)

                // Fields for the selected method
                if selectedMethod == .local {
                    VStack(spacing: 16) {
                        WizardInputField(label: String(localized: "setup.identity.label.nsec"), text: $nsec, placeholder: "nsec1...", isSecure: true)
                            .onChange(of: nsec) { _, newValue in
                                fillNpub(fromNsec: newValue)
                            }

                        if !nsec.isEmpty && derivedNpub == nil {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                Text(String(localized: "setup.identity.invalidNsec"))
                                    .font(.appSystem(size: 13))
                            }
                            .foregroundColor(WizardColors.error)
                        }

                        if !nsec.isEmpty {
                            WizardInputField(label: String(localized: "setup.identity.label.password"), text: $nsecPassword, placeholder: "Enter password...", isSecure: true)
                                .transition(.move(edge: .top).combined(with: .opacity))

                            Text(String(localized: "setup.identity.passwordHint"))
                                .font(.appSystem(size: 12))
                                .foregroundColor(WizardColors.textMuted)

                            if nsecPassword.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.caption)
                                    Text(String(localized: "setup.identity.passwordRequired"))
                                        .font(.appSystem(size: 13))
                                }
                                .foregroundColor(WizardColors.accentPrimary)
                            }
                        }

                        Button(action: generateNewIdentity) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(WizardColors.accentPrimary)
                                Text(String(localized: "setup.identity.generateKeys"))
                                    .font(.appSystem(size: 14, weight: .medium))
                                    .foregroundColor(WizardColors.accentPrimary)
                            }
                        }
                        .buttonStyle(.plain)

                        if generatedKeys {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundColor(WizardColors.accentPrimary)
                                Text(String(localized: "setup.identity.nsecWarning"))
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(WizardColors.accentPrimary)
                            }
                            .padding(12)
                            .background(WizardColors.accentPrimary.opacity(0.1))
                            .cornerRadius(10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    VStack(spacing: 12) {
                        if !bunkerConnected {
                            SignInWithClaveView { request, signerPubkey in
                                try await signInWithClave(request, signerPubkey: signerPubkey)
                            }
                            .tint(WizardColors.accentPrimary)

                            Text("Or paste a bunker link from any signer app")
                                .font(.appSystem(size: 12))
                                .foregroundColor(WizardColors.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        WizardInputField(
                            label: String(localized: "setup.identity.label.bunker"),
                            text: $bunkerURI,
                            placeholder: "bunker://...",
                            isDisabled: bunkerConnected,
                            onScan: { activeScanner = .bunker }
                        )

                        Text(String(localized: "setup.identity.bunkerHint"))
                            .font(.appSystem(size: 12))
                            .foregroundColor(WizardColors.textMuted)

                        if let error = bunkerError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                Text(error)
                                    .font(.appSystem(size: 13))
                            }
                            .foregroundColor(WizardColors.error)
                        }

                        if bunkerConnected {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(WizardColors.success)
                                Text(String(localized: "setup.identity.bunkerConnected"))
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(WizardColors.success)
                            }
                        }

                        HStack(spacing: 12) {
                            WizardPrimaryButton(
                                title: bunkerConnected ? String(localized: "setup.identity.bunker.disconnect") : String(localized: "setup.identity.bunker.connect"),
                                action: {
                                    if bunkerConnected {
                                        disconnectBunker()
                                    } else {
                                        testBunkerConnection()
                                    }
                                },
                                disabled: bunkerURI.isEmpty || isConnectingBunker
                            )

                            if isConnectingBunker {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(WizardColors.accentPrimary)
                            }
                        }

                        if isConnectingBunker {
                            Text("Approve the connection in your signer app")
                                .font(.appSystem(size: 12, weight: .regular))
                                .foregroundColor(WizardColors.textSecondary)
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            WizardPrimaryButton(
                title: isBrowseMode && looksLikeNIP05 && !isNpubValid ? "Resolve & Continue" : String(localized: "setup.action.continue"),
                action: { handleContinue() },
                disabled: !canContinue
            )

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        #if os(iOS)
        .sheet(item: $activeScanner) { target in
            switch target {
            case .identity:
                QRScannerView { scannedCode in
                    activeScanner = nil
                    // Strip nostr: prefix if present
                    let cleaned = scannedCode.hasPrefix("nostr:") ? String(scannedCode.dropFirst(6)) : scannedCode
                    identityInput = cleaned
                }
            case .bunker:
                QRScannerView(
                    title: String(localized: "setup.identity.bunkerScan.title"),
                    validate: { code in
                        BunkerURI.normalized(code) == nil
                            ? String(localized: "setup.identity.bunkerScan.notBunker")
                            : nil
                    }
                ) { scannedCode in
                    activeScanner = nil
                    guard let uri = BunkerURI.normalized(scannedCode) else { return }
                    bunkerURI = uri
                    bunkerError = nil
                }
            }
        }
        #endif
    }

    private func handleContinue() {
        if isBrowseMode {
            if isNpubValid {
                onContinue()
            } else if looksLikeNIP05 {
                resolveNIP05()
            }
        } else {
            onContinue()
        }
    }

    private func resolveNIP05() {
        let input = identityInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isResolvingNIP05 = true
        nip05Error = nil
        resolvedFromNIP05 = nil

        Task {
            do {
                // Parse user@domain or bare domain (implies _@domain)
                let user: String
                let domain: String
                if input.contains("@") {
                    let parts = input.split(separator: "@", maxSplits: 1)
                    guard parts.count == 2 else {
                        throw NIP05Error.invalidFormat
                    }
                    user = String(parts[0])
                    domain = String(parts[1])
                } else {
                    user = "_"
                    domain = input
                }

                guard !domain.isEmpty, domain.contains(".") else {
                    throw NIP05Error.invalidFormat
                }

                // Fetch .well-known/nostr.json
                guard let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(user)") else {
                    throw NIP05Error.invalidFormat
                }

                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw NIP05Error.serverError
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let names = json["names"] as? [String: String],
                      let hexPubkey = names[user] else {
                    throw NIP05Error.nameNotFound
                }

                // Validate hex pubkey (64 hex chars = 32 bytes)
                guard hexPubkey.count == 64, hexPubkey.allSatisfy({ $0.isHexDigit }) else {
                    throw NIP05Error.invalidPubkey
                }

                // Convert to npub
                guard let pubData = Bech32.hexToData(hexPubkey),
                      let resolvedNpub = Bech32.encode(hrp: "npub", data: pubData) else {
                    throw NIP05Error.invalidPubkey
                }

                await MainActor.run {
                    npub = resolvedNpub
                    resolvedFromNIP05 = resolvedNpub
                    isResolvingNIP05 = false
                    onContinue()
                }
            } catch let error as NIP05Error {
                await MainActor.run {
                    nip05Error = error.displayMessage
                    isResolvingNIP05 = false
                }
            } catch {
                await MainActor.run {
                    nip05Error = "Failed to resolve NIP-05: \(error.localizedDescription)"
                    isResolvingNIP05 = false
                }
            }
        }
    }

    private enum NIP05Error: Error {
        case invalidFormat, serverError, nameNotFound, invalidPubkey

        var displayMessage: String {
            switch self {
            case .invalidFormat: return "Invalid NIP-05 format. Use user@domain.com"
            case .serverError: return "Could not reach the NIP-05 server"
            case .nameNotFound: return "Name not found on that domain"
            case .invalidPubkey: return "Server returned an invalid public key"
            }
        }
    }

    /// The npub of the nsec field, or nil while it doesn't hold a valid key.
    private var derivedNpub: String? {
        guard let decoded = Bech32.decode(nsec), decoded.hrp == "nsec",
              let pkCStr = withCStrings([decoded.hexString], { p in GetPublicKeyC(p[0]) }) else { return nil }
        let pk = String(cString: pkCStr)
        free(pkCStr)
        guard let pubData = Bech32.hexToData(pk) else { return nil }
        return Bech32.encode(hrp: "npub", data: pubData)
    }

    /// A pasted nsec is the whole identity: derive its npub so the user
    /// isn't left with a disabled Continue and an empty npub field to fill
    /// by hand (or filled with an npub that doesn't match the key).
    private func fillNpub(fromNsec value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean != value {
            nsec = clean // pasted keys often carry a trailing newline
            return
        }
        if let derivedNpub {
            npub = derivedNpub
        }
    }

    private func generateNewIdentity() {
        guard let resultCStr = GenerateKeyPairC() else { return }
        let result = String(cString: resultCStr)
        let parts = result.split(separator: ":")
        guard parts.count == 2 else { return }
        let sk = String(parts[0])
        let pk = String(parts[1])

        if let pubData = Bech32.hexToData(pk),
           let generatedNpub = Bech32.encode(hrp: "npub", data: pubData) {
            npub = generatedNpub
        }

        if let secData = Bech32.hexToData(sk),
           let generatedNsec = Bech32.encode(hrp: "nsec", data: secData) {
            nsec = generatedNsec
        }

        withAnimation(WizardAnimations.springBounce) {
            generatedKeys = true
        }
    }

    private func signingMethodCard(method: SigningMethod, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = selectedMethod == method
        return Button {
            withAnimation(WizardAnimations.springEnter) {
                selectedMethod = method
                signingMode = method == .nip46 ? "nip46" : "local"
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.appSystem(size: 24))
                    .foregroundColor(isSelected ? WizardColors.accentPrimary : WizardColors.textSecondary)

                Text(title)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)

                Text(subtitle)
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? WizardColors.accentPrimary.opacity(0.5) : WizardColors.borderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? WizardColors.accentGlow : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }

    private func testBunkerConnection() {
        isConnectingBunker = true
        bunkerError = nil
        bunkerConnected = false

        Task {
            do {
                let info = try NIP46Service.parseBunkerURI(bunkerURI)
                ConfigService.shared.config.nip46SignerPubkey = info.signerPubkey
                ConfigService.shared.config.nip46RelayURL = info.relayURL
                ConfigService.shared.config.nip46Secret = info.secret
                // Also store the full original URI: a bunker:// URI can list multiple
                // relay= params, but parseBunkerURI/nip46RelayURL only ever keep the
                // first one. connect() prefers nip46BunkerURI (the untruncated string)
                // when present, so reconnects still have every relay to fall back to.
                ConfigService.shared.config.nip46BunkerURI = bunkerURI
                ConfigService.shared.config.signingMode = "nip46"
                ConfigService.shared.save()

                // No account exists yet during setup: the signer's key becomes it.
                let pubkey = try await NIP46Service.shared.connect(adoptSignerAccount: true)

                if let pubData = Bech32.hexToData(pubkey),
                   let generatedNpub = Bech32.encode(hrp: "npub", data: pubData) {
                    npub = generatedNpub
                }

                bunkerConnected = true
                isConnectingBunker = false
            } catch {
                bunkerError = error.localizedDescription
                isConnectingBunker = false
                ConfigService.shared.config.signingMode = "local"
            }
        }
    }

    /// Finishes a "Sign in with Clave" pairing: store it the way a pasted
    /// bunker link is stored, then connect, adopting the signer's key as the
    /// new account.
    private func signInWithClave(_ request: NIP46Service.NostrConnectRequest, signerPubkey: String) async throws {
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
            if let pubData = Bech32.hexToData(pubkey),
               let signerNpub = Bech32.encode(hrp: "npub", data: pubData) {
                npub = signerNpub
            }
            bunkerURI = uri
            bunkerConnected = true
            bunkerError = nil
        } catch {
            config.config.signingMode = "local"
            throw error
        }
    }

    private func disconnectBunker() {
        NIP46Service.shared.disconnect()
        bunkerConnected = false
        npub = ""
        ConfigService.shared.config.signingMode = "local"
        ConfigService.shared.config.nip46SignerPubkey = ""
        ConfigService.shared.config.nip46RelayURL = ""
        ConfigService.shared.config.nip46Secret = ""
        ConfigService.shared.config.nip46BunkerURI = ""
    }
}
