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

// MARK: - Import tour

/// Import starts as soon as this shows. Over it, the import tour's lesson
/// cards at the reader's own pace, then a Ready card with real counts.
/// Import done first: "Jump in" shows under any card. Cards done first: the
/// app can open with the import still running (it lives in
/// `RelayProcessManager`, not this view).
struct ImportTourStep: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    let isReadOnly: Bool
    /// `keptRunning`: they left with the import still going.
    let onEnter: (_ keptRunning: Bool) -> Void

    @State private var index = 0
    @State private var counts: (notes: Int, likes: Int, all: Int)?
    @State private var started = false

    /// Same as the config default. 2021 was tried: the import walks the
    /// history in 10-day windows, each waiting on every relay, and a fresh
    /// key spent ~10 s per empty window on the simulator (2026-10-07), so
    /// two more years cost minutes for everyone. Older notes can be pulled
    /// from Settings → Import.
    static let importStartDate = "2023-01-01"

    private var lessons: [TutorialStep] { TutorialContent.importTour }
    /// The small orange label over each lesson (mockup).
    static let kickers = ["WHY IMPORT", "HOW IT WORKS", "RELAYS", "OPTIONAL", "FEEDS"]
    private var lastIndex: Int { lessons.count }  // the Ready card
    private var done: Bool { relayManager.importCompleted && !relayManager.isImporting }
    private var stage: ImportTourStage {
        ImportTourStage(statusMessage: relayManager.importStatusMessage, completed: done)
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text("Bringing your notes home")
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
            progressHeader
            card
            if done && index < lastIndex {
                doneBar
            }
        }
        .onAppear(perform: startImportOnce)
        .onChange(of: done) { _, isDone in
            if isDone { loadCounts() }
        }
    }

    // MARK: Progress

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stage.text)
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(done ? WizardColors.success : WizardColors.textSecondary)
                Spacer()
                Text("\(stage.step) of \(ImportTourStage.stepCount)")
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
            ProgressView(value: done ? 1 : max(relayManager.importProgress, 0.02))
                .tint(done ? WizardColors.success : WizardColors.accentPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Import"))
        .accessibilityValue(Text(stage.text))
    }

    // MARK: Cards

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if index < lastIndex {
                let lesson = lessons[index]
                Text(Self.kickers[index])
                    .font(.appSystem(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(WizardColors.accentPrimary)
                Text(lesson.title)
                    .font(.appSystem(size: 20, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                Text(lesson.body)
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ImportTourArt(lesson: index)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            } else {
                Text("READY")
                    .font(.appSystem(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundColor(WizardColors.accentPrimary)
                readyCard
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { index -= 1 }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .opacity(index == 0 ? 0 : 1)
                    .disabled(index == 0)
                    .foregroundColor(WizardColors.textSecondary)
                Spacer()
                pips
                Spacer()
                if index < lastIndex {
                    Button { index += 1 } label: {
                        Text("Next")
                            .font(.appSystem(size: 15, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(WizardColors.accentGradient)
                            .cornerRadius(12)
                    }
                } else {
                    Button { enter(keptRunning: false) } label: {
                        Text("Enter")
                            .font(.appSystem(size: 15, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(WizardColors.accentGradient)
                            .cornerRadius(12)
                            .opacity(done ? 1 : 0.4)
                    }
                    .disabled(!done)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(WizardColors.bgCard)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(WizardColors.borderSubtle, lineWidth: 1))
        .animation(WizardAnimations.fadeIn, value: index)
    }

    private var pips: some View {
        HStack(spacing: 6) {
            ForEach(0...lastIndex, id: \.self) { i in
                Circle()
                    .fill(i == index ? WizardColors.accentPrimary : WizardColors.borderSubtle)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Card \(index + 1) of \(lastIndex + 1)"))
    }

    @ViewBuilder
    private var readyCard: some View {
        Text(done ? "Your notes are home" : "Almost there")
            .font(.appSystem(size: 20, weight: .semibold))
            .foregroundColor(WizardColors.textPrimary)
        if done {
            Text("Everything we found is saved on this device.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
            if let counts {
                HStack(spacing: 10) {
                    countTile(counts.notes, "notes")
                    countTile(counts.likes, "likes")
                    countTile(counts.all, "in all")
                }
            }
            if isReadOnly {
                Text("Read-only for now. Add your private key in Settings to post.")
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
            }
        } else {
            Text("Still importing. That's normal for a long history, so you can wait here or keep it running in the background.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Keep it running in the background") { enter(keptRunning: true) }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.accentPrimary)
                .buttonStyle(.plain)
        }
    }

    private func countTile(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.appSystem(size: 18, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
            Text(label)
                .font(.appSystem(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(WizardColors.bgElevated)
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }

    private var doneBar: some View {
        HStack {
            Label("Import done. Your notes are home.", systemImage: "checkmark.circle.fill")
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(WizardColors.success)
            Spacer()
            Button("Jump in") { enter(keptRunning: false) }
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(WizardColors.accentGradient)
                .cornerRadius(10)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(WizardColors.success.opacity(0.12))
        .cornerRadius(12)
    }

    // MARK: Actions

    private func startImportOnce() {
        guard !started else { return }
        started = true
        if done { loadCounts(); return }
        guard !relayManager.isImporting else { return }
        configService.config.importStartDate = Self.importStartDate
        configService.save()
        relayManager.importNotes(config: configService.config)
    }

    /// Seeing every lesson card finishes the tour (and covers Vault and
    /// Pocket relay); leaving before the last one counts as skipped.
    private func enter(keptRunning: Bool) {
        let account = Bech32.decode(npubForAccount)?.hexString ?? ""
        if index >= lastIndex {
            TutorialCenter.shared.finish(.importTour, account: account)
        } else {
            TutorialCenter.shared.skip(.importTour, account: account)
        }
        onEnter(keptRunning)
    }

    private var npubForAccount: String { configService.config.ownerNpub }

    private func loadCounts() {
        Task {
            _ = await relayManager.ensureRelayReady(timeout: 30)
            let byKind = await StatsService.shared.fetchCountsByKind()
            counts = (byKind[1] ?? 0, byKind[7] ?? 0, byKind[-1] ?? 0)
        }
    }
}

// MARK: - Background pill

/// "Importing · notes from Mar 2024": shown over the app
/// while an import runs after setup (I use Nostr's "Keep it running", or an
/// import started from Settings). Not a button, so it takes no touches.
struct ImportRunningPill: View {
    @ObservedObject private var relayManager = RelayProcessManager.shared
    @ObservedObject private var configService = ConfigService.shared

    var body: some View {
        if relayManager.isImporting && configService.config.hasCompletedSetup {
            let stage = ImportTourStage(statusMessage: relayManager.importStatusMessage, completed: false)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Importing · \(Self.shortText(stage))")
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    /// "Saving your notes from Mar 2024…" → "notes from Mar 2024".
    static func shortText(_ stage: ImportTourStage) -> String {
        stage.text
            .replacingOccurrences(of: "Saving your ", with: "")
            .replacingOccurrences(of: "Saving ", with: "")
            .replacingOccurrences(of: "Looking through ", with: "")
            .replacingOccurrences(of: "…", with: "")
            .lowercasedFirst
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Lesson pictures

/// The small diagram under each import-tour lesson (mockup's pictures,
/// drawn with SF Symbols). Decorative: the text says the same thing.
struct ImportTourArt: View {
    let lesson: Int

    private let accent = WizardColors.accentPrimary
    private let muted = WizardColors.textMuted

    var body: some View {
        Group {
            switch lesson {
            case 0: why
            case 1: pocket
            case 2: publicVsYours
            case 3: macAddress
            default: webOfTrust
            }
        }
        .frame(height: 110)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String, _ color: Color, size: CGFloat = 30) -> some View {
        Image(systemName: name).font(.system(size: size, weight: .regular)).foregroundColor(color)
    }

    private func caption(_ text: String, _ color: Color = WizardColors.textSecondary) -> some View {
        Text(text).font(.appSystem(size: 10, weight: .medium)).foregroundColor(color)
    }

    /// A relay, a deleted relay, and the copy on your phone.
    private var why: some View {
        HStack(spacing: 18) {
            VStack(spacing: 10) {
                VStack(spacing: 2) { symbol("server.rack", WizardColors.textSecondary, size: 22); caption("relay") }
                VStack(spacing: 2) {
                    symbol("server.rack", muted, size: 22)
                        .overlay(symbol("xmark", WizardColors.error, size: 16))
                    caption("deleted", muted)
                }
            }
            symbol("arrow.right", accent, size: 20)
            VStack(spacing: 2) { symbol("iphone", accent, size: 44); caption("your copy", WizardColors.textPrimary) }
        }
    }

    /// Your relay sends out; nothing reaches in.
    private var pocket: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                symbol("network", muted, size: 22)
                caption("network", muted)
            }
            symbol("nosign", WizardColors.error, size: 18)
            VStack(spacing: 2) { symbol("iphone.radiowaves.left.and.right", accent, size: 44); caption("your relay", WizardColors.textPrimary) }
            VStack(spacing: 6) {
                symbol("arrow.up.right", accent, size: 16)
                symbol("arrow.right", accent, size: 16)
                symbol("arrow.down.right", accent, size: 16)
            }
        }
    }

    /// Yours sends a post out to the shared public relays.
    private var publicVsYours: some View {
        HStack(spacing: 18) {
            VStack(spacing: 2) { symbol("iphone", accent, size: 44); caption("yours", WizardColors.textPrimary) }
            symbol("arrow.right", accent, size: 20)
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 4) { symbol("server.rack", WizardColors.textSecondary, size: 16); caption("public") }
                }
            }
        }
    }

    /// A Mac with your own address; your phone syncs from it.
    private var macAddress: some View {
        HStack(spacing: 16) {
            symbol("iphone", WizardColors.textSecondary, size: 34)
            symbol("arrow.left.arrow.right", muted, size: 16)
            VStack(spacing: 4) {
                symbol("desktopcomputer", accent, size: 46)
                caption("relay.you.com", WizardColors.textPrimary)
                caption("up 24/7")
            }
        }
    }

    /// You, your follows, and the people they follow.
    private var webOfTrust: some View {
        let center = CGPoint(x: 60, y: 50)
        let points = (0..<6).map { k -> CGPoint in
            let angle = Double(k) * .pi / 3
            return CGPoint(x: center.x + 44 * cos(angle), y: center.y + 38 * sin(angle))
        }
        return ZStack {
            Path { p in
                for point in points {
                    p.move(to: center)
                    p.addLine(to: point)
                }
            }
            .stroke(accent.opacity(0.5), lineWidth: 1)
            ForEach(points.indices, id: \.self) { k in
                symbol("person.circle.fill", WizardColors.textSecondary, size: 20)
                    .position(points[k])
            }
            symbol("person.circle.fill", accent, size: 30)
                .position(center)
        }
        .frame(width: 120, height: 100)
    }
}

// MARK: - Relay check

/// Between Your key and the import tour: checks which relays answer and
/// have this person's notes, so the import can't hang on a dead one.
/// "Start import" saves the picks to `importSeedRelays`, which is what the
/// import reads.
struct RelayCheckStep: View {
    @EnvironmentObject var configService: ConfigService
    let npub: String
    let onStart: () -> Void

    @State private var rows: [RelayCheck.Row] = []
    @State private var isChecking = true
    @State private var editing = false
    @State private var newRelay = ""
    @State private var started = false

    private var pubkey: String { Bech32.decode(npub)?.hexString ?? "" }
    private var onCount: Int { rows.filter(\.isOn).count }

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text(isChecking ? "Checking your relays" : "Ready to import")
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
            Text(isChecking ? "Looking for your notes. This takes a few seconds." : RelayCheck.summary(rows))
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach($rows) { $row in
                    relayRow($row)
                    if row.id != rows.last?.id {
                        Divider().background(WizardColors.borderSubtle)
                    }
                }
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))

            if editing {
                addRow
            }

            WizardPrimaryButton(title: "Start import", action: start, disabled: isChecking || onCount == 0)

            Button(editing ? "Done" : "Change import relays") { editing.toggle() }
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(minHeight: 44)
                .disabled(isChecking)
                .buttonStyle(.plain)
        }
        .task {
            guard !started else { return }
            started = true
            await runCheck()
        }
    }

    private func relayRow(_ row: Binding<RelayCheck.Row>) -> some View {
        let value = row.wrappedValue
        let dot: Color = switch value.result {
        case .checking: WizardColors.textMuted
        case .ready: WizardColors.success
        case .slow: WizardColors.accentPrimary
        case .notAnswering, .refused, .needsSignIn: WizardColors.error
        }
        return HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(value.url.replacingOccurrences(of: "wss://", with: ""))
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                        .lineLimit(1)
                    if value.isYours {
                        Text("yours")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(WizardColors.accentPrimary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(WizardColors.accentPrimary.opacity(0.15))
                            .cornerRadius(6)
                    }
                }
                Text(value.result.label)
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textSecondary)
            }
            Spacer(minLength: 0)
            if editing {
                Toggle("Import from \(value.url)", isOn: row.isOn)
                    .labelsHidden()
                    .tint(WizardColors.accentPrimary)
                    .disabled(!value.result.canImport)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: editing ? .contain : .combine)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Add a relay, e.g. relay.example.com", text: $newRelay)
                .textFieldStyle(.plain)
                .font(.appSystem(size: 14))
                .foregroundColor(WizardColors.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .submitLabel(.done)
                .onSubmit(addRelay)
            Button("Add", action: addRelay)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(RelayCheck.normalize(newRelay) == nil)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .background(WizardColors.bgCard)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WizardColors.borderSubtle, lineWidth: 1))
    }

    // MARK: Actions

    private func runCheck() async {
        // Their relay list says where their notes are; the defaults are
        // where most people's notes also land.
        let list = await NostrService.shared.fetchNewestReplaceable(
            kind: 10002, for: pubkey, alsoAsk: configService.config.importSeedRelays
        )
        rows = RelayCheck.rows(relayListTags: list?.tags ?? [], defaults: HavenConfig().importSeedRelays)
        await withTaskGroup(of: (String, RelayCheck.Result).self) { group in
            for row in rows {
                group.addTask { @MainActor in
                    (row.url, await RelayCheckProbe.check(url: row.url, pubkey: pubkey))
                }
            }
            for await (url, result) in group {
                if let i = rows.firstIndex(where: { $0.url == url }) {
                    rows[i].result = result
                    rows[i].isOn = result.onByDefault
                }
            }
        }
        isChecking = false
    }

    private func addRelay() {
        guard let url = RelayCheck.normalize(newRelay), !rows.contains(where: { $0.url == url }) else { return }
        newRelay = ""
        rows.append(RelayCheck.Row(url: url, isYours: false))
        Task {
            let result = await RelayCheckProbe.check(url: url, pubkey: pubkey)
            if let i = rows.firstIndex(where: { $0.url == url }) {
                rows[i].result = result
                rows[i].isOn = result.onByDefault
            }
        }
    }

    private func start() {
        configService.config.importSeedRelays = RelayCheck.importList(rows)
        configService.save()
        onStart()
    }
}
