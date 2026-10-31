import SwiftUI

// MARK: - Ambient Gradient Background

private struct AmbientGradientView: View {
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate * 0.08
                let cx = size.width * 0.5 + sin(t) * size.width * 0.1
                let cy = size.height * 0.4 + cos(t * 0.7) * size.height * 0.08
                let radius = min(size.width, size.height) * 0.45

                let gradient = Gradient(colors: [
                    Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.15),
                    Color(red: 0.918, green: 0.345, blue: 0.047).opacity(0.08),
                    Color.clear
                ])
                let shading = GraphicsContext.Shading.radialGradient(
                    gradient,
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endRadius: radius
                )
                context.fill(Path(CGRect(origin: .zero, size: size)), with: shading)
            }
        }
        .ignoresSafeArea()
    }
}

private struct StepDots: View {
    let totalSteps: Int
    let currentStep: Int
    @Namespace private var dotNamespace

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Circle()
                    .fill(index <= currentStep ? WizardColors.accentPrimary : WizardColors.borderSubtle)
                    .frame(width: index == currentStep ? 10 : 6, height: index == currentStep ? 10 : 6)
                    .shadow(color: index == currentStep ? WizardColors.accentGlow : .clear, radius: 4)
                    .animation(WizardAnimations.springEnter, value: currentStep)
            }
        }
        .padding(.vertical, 16)
    }
}

// MARK: - Main Wizard View

struct SetupWizardView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @Environment(\.dismiss) var dismiss

    // Navigation state
    @State private var currentStep = 0
    @State private var setupPath: SetupPath = .none
    @State private var direction: TransitionDirection = .forward

    // Identity state
    @State private var npub = ""
    @State private var nsec = ""
    @State private var nsecPassword = ""
    @State private var signingMode = "local"
    @State private var bunkerURI = ""
    @State private var bunkerConnected = false

    // Relay state
    @State private var relayURL = ""
    @State private var macRelayURL = ""

    // Wallet state
    @State private var nwcURI = ""

    // New account state: published once setup completes and the key can sign
    @State private var profileName = ""
    @State private var profilePhotoJPEG: Data?
    /// The relay list to publish for the new key (step 17); nil publishes none.
    @State private var starterRelayList: [String]?
    /// Their own relays picked in the relay check: the import reads them,
    /// nothing saves them.
    @State private var importOwnRelays: [String] = []

    // Error state
    @State private var setupError: String?
    @State private var showSetupError = false

    let onComplete: () -> Void

    enum SetupPath {
        /// `useNostr` is iPhone/iPad's "I use Nostr": one key field decides
        /// read-only vs can-post, so it replaces `full` and `browse` there.
        /// The Mac keeps those two (Full Setup there is a public relay).
        case none, full, browse, newToNostr, useNostr
    }

    enum TransitionDirection {
        case forward, backward
    }

    // Map of actual step numbers to dot positions, one array per path. Single
    // source of truth for both the dot count and the highlighted index — they
    // used to be maintained separately (a literal count here, a duplicate
    // array in currentDotIndex) and drifted apart, undercounting the real
    // step total by one on three of the four paths (browse: 4 vs 5 steps;
    // full iOS: 8 vs 9; full macOS: 7 vs 8) so the dots ran out before the
    // wizard did.
    //
    // Welcome (step 0) is the front door, not step 1 of N: it shows no dots,
    // and picking a way in there is what sets the path.
    private var pathSteps: [Int] {
        switch setupPath {
        case .none: return []
        case .newToNostr: return [9, 10, 11, 17, 15, 8] // keys, password, profile, relay list, who told you, done
        // Existing Nostr users: the Vault backup question comes before the relay import.
        case .browse: return VaultBackupQuestion.steps(path: .browse, isIOS: isIOSDevice)
        case .full:
            // macOS full setup: who told you (15) after the wallet.
            let steps = VaultBackupQuestion.steps(path: .full, isIOS: isIOSDevice)
            return isIOSDevice ? steps : Self.addingReferrer(to: steps, before: 8)
        case .useNostr:
            // your key, Vault backup?, relay check, (who told you), import tour.
            // A read-only key can't follow anyone.
            let steps = VaultBackupQuestion.steps(path: .useNostr, isIOS: isIOSDevice)
            return useNostrIsReadOnly ? steps : Self.addingReferrer(to: steps, before: 13)
        }
    }

    /// `steps` with "Who told you about Nostr Vault?" (15) right before `next`.
    private static func addingReferrer(to steps: [Int], before next: Int) -> [Int] {
        var out = steps
        out.insert(15, at: out.firstIndex(of: next) ?? out.endIndex)
        return out
    }

    /// The path as the Vault backup question knows it; nil for a new account.
    private var backupQuestionPath: VaultBackupQuestion.Path? {
        switch setupPath {
        case .useNostr: return .useNostr
        case .full: return .full
        case .browse: return .browse
        case .none, .newToNostr: return nil
        }
    }

    private var totalVisibleSteps: Int { pathSteps.count }

    /// "I use Nostr" with only a public key: nothing to sign with.
    private var useNostrIsReadOnly: Bool { signingMode != "nip46" && nsec.isEmpty }

    private var currentDotIndex: Int {
        pathSteps.firstIndex(of: currentStep) ?? 0
    }

    var body: some View {
        ZStack {
            // Full-screen dark background
            WizardColors.bgPrimary.ignoresSafeArea()

            // Ambient gradient
            AmbientGradientView()

            if currentStep == 0 {
                // Outside the ScrollView so it can fill the height and pin
                // its buttons to the bottom.
                WelcomeStepView(onChoose: choosePath)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Back button
                    HStack {
                        Button(action: goBack) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(String(localized: "setup.nav.back"))
                            }
                            .font(.appSystem(size: 14, weight: .medium))
                            .foregroundColor(WizardColors.textMuted)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .frame(height: 36)

                    // Content area
                    ScrollView {
                        VStack {
                            stepContent
                                .frame(maxWidth: 560)
                                .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Step dots
                    StepDots(totalSteps: totalVisibleSteps, currentStep: currentDotIndex)
                }
            }

            // Process kill alert overlay
            if relayManager.showProcessKillAlert {
                processKillOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(String(localized: "setup.alert.error.title"), isPresented: $showSetupError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(setupError ?? String(localized: "setup.alert.error.unknown"))
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 2:
            IdentityStepView(
                isBrowseMode: setupPath == .browse,
                npub: $npub,
                nsec: $nsec,
                nsecPassword: $nsecPassword,
                signingMode: $signingMode,
                bunkerURI: $bunkerURI,
                bunkerConnected: $bunkerConnected,
                onContinue: { goForward() }
            )
        case 3:
            RelayConfigStep(
                relayURL: $relayURL,
                macRelayURL: $macRelayURL,
                onContinue: { goForward() },
                onSkip: { goForward() }
            )
        case 4:
            ImportNotesStep(onContinue: { goForward() }, onSkip: { goForward() })
        case 5:
            MirrorMediaStep(onContinue: { goForward() }, onSkip: { goForward() })
        case 6:
            WalletSetupStep(
                nwcURI: $nwcURI,
                onContinue: {
                    if isIOSDevice {
                        goForward() // Go to notifications
                    } else {
                        currentStep = 15 // Who told you, then complete
                    }
                },
                onSkip: {
                    if isIOSDevice {
                        goForward()
                    } else {
                        currentStep = 15
                    }
                }
            )
        case 7:
            if isIOSDevice {
                PushNotificationStep(onContinue: { currentStep = 8 }, onSkip: { currentStep = 8 })
            } else {
                // macOS browse mode lands here as "complete"
                CompleteStep(isBrowseMode: setupPath == .browse, isNewUser: setupPath == .newToNostr, onLaunch: { saveAndComplete() })
            }
        case 8:
            CompleteStep(isBrowseMode: setupPath == .browse, isNewUser: setupPath == .newToNostr, onLaunch: { saveAndComplete() })
        case 9:
            NostrIntroStep(
                npub: $npub,
                nsec: $nsec,
                onContinue: {
                    direction = .forward
                    withAnimation(WizardAnimations.springEnter) {
                        currentStep = 10
                    }
                }
            )
        case 10:
            KeyPasswordStep(
                nsecPassword: $nsecPassword,
                onContinue: {
                    saveIntermediateConfig()
                    direction = .forward
                    withAnimation(WizardAnimations.springEnter) {
                        currentStep = 11
                    }
                }
            )
        case 11:
            NewProfileStep(
                name: $profileName,
                photoJPEG: $profilePhotoJPEG,
                onContinue: {
                    direction = .forward
                    withAnimation(WizardAnimations.springEnter) {
                        currentStep = 17
                    }
                }
            )
        case 17:
            StarterRelayListStep(starter: starterRelays) { relays in
                // Published in publishNewAccount, once the key is stored.
                starterRelayList = relays.isEmpty ? nil : relays
                direction = .forward
                withAnimation(WizardAnimations.springEnter) {
                    currentStep = 15
                }
            }
        case 15:
            ReferrerStep(
                ownPubkey: NpubValidation.hexPubkey(fromNpub: npub),
                excludeOwnFollows: setupPath != .newToNostr,
                onFinish: { follows in
                    // Followed in saveAndComplete, once the key is stored.
                    SetupReferral().pendingFollows = follows
                    goForward()
                }
            )
        case 12:
            UseNostrKeyStep(
                npub: $npub,
                nsec: $nsec,
                nsecPassword: $nsecPassword,
                signingMode: $signingMode,
                bunkerURI: $bunkerURI,
                onContinue: { goForward() }
            )
        case VaultBackupQuestion.step:
            VaultBackupQuestionStep(
                onRestored: { answerBackupQuestion(.restored) },
                onNo: { answerBackupQuestion(.no) }
            )
        case 14:
            RelayCheckStep(npub: npub) { own in
                importOwnRelays = own
                goForward()
            }
        case 13:
            ImportTourStep(isReadOnly: useNostrIsReadOnly, alsoFrom: importOwnRelays) { _ in
                // Kept running or not, the import carries on in
                // RelayProcessManager; startRelay waits for it.
                saveAndComplete()
            }
        default:
            EmptyView()
        }
    }

    /// The front door's buttons. New to Nostr goes to the intro, I use Nostr
    /// (iPhone/iPad) to its key step; full setup and browse (Mac) both start
    /// at identity.
    private func choosePath(_ path: SetupPath) {
        setupPath = path
        // Follows picked on an earlier way through are not this run's.
        SetupReferral().pendingFollows = []
        direction = .forward
        withAnimation(WizardAnimations.springEnter) {
            switch path {
            case .newToNostr: currentStep = 9
            case .useNostr: currentStep = 12
            default: currentStep = 2
            }
        }
        if path == .newToNostr || path == .useNostr {
            saveIntermediateConfig()
        }
    }

    private func goForward() {
        direction = .forward
        withAnimation(WizardAnimations.springEnter) {
            if let path = backupQuestionPath, VaultBackupQuestion.isAskedAfter(step: currentStep, path: path) {
                currentStep = VaultBackupQuestion.step // → Do you have a Vault backup?
            } else if currentStep == 14 {
                // relay check → who told you → import tour
                currentStep = useNostrIsReadOnly ? 13 : 15
            } else if currentStep == 15 {
                currentStep = setupPath == .useNostr ? 13 : 8
            } else if currentStep == 4 && setupPath == .browse {
                // Browse mode: after import, skip mirror/wallet/notifications — go to complete
                currentStep = 8
            } else if currentStep == 6 && !isIOSDevice {
                // macOS full setup: skip notifications, go to who told you
                currentStep = 15
            } else {
                currentStep += 1
            }
        }
        // Save intermediate config at key points
        // The import tour (13) imports with the saved config, so save first.
        if currentStep >= 3 || (currentStep == 8 && setupPath == .browse) || currentStep == 9 || currentStep == 11 {
            saveIntermediateConfig()
        }
    }

    private func goBack() {
        direction = .backward
        withAnimation(WizardAnimations.springEnter) {
            if currentStep == 12 || currentStep == 9 || currentStep == 2 {
                currentStep = 0 // Back to the front door
            } else if currentStep == VaultBackupQuestion.step, let path = backupQuestionPath {
                currentStep = VaultBackupQuestion.previous(path: path)
            } else if currentStep == 14 || (currentStep == 4 && backupQuestionPath != nil) {
                currentStep = VaultBackupQuestion.step // Relay import: back to the backup question
            } else if currentStep == 13 {
                currentStep = useNostrIsReadOnly ? 14 : 15 // Import tour: back to who told you / the relay check
            } else if currentStep == 15 {
                // Who told you: back to profile, the relay check or the wallet
                currentStep = setupPath == .newToNostr ? 17 : setupPath == .useNostr ? 14 : 6
            } else if currentStep == 17 {
                currentStep = 11 // Relay list: back to profile
            } else if currentStep == 11 {
                currentStep = 10 // Profile: back to password
            } else if currentStep == 10 {
                currentStep = 9 // Password: back to your keys
            } else if currentStep == 8 {
                if setupPath == .newToNostr {
                    currentStep = 15 // New to Nostr: back to who told you
                } else if setupPath == .browse {
                    currentStep = 4 // Browse: back to import
                } else if isIOSDevice {
                    currentStep = 7 // iOS full: back to notifications
                } else {
                    currentStep = 15 // macOS full: back to who told you
                }
            } else if currentStep == 7 && isIOSDevice {
                currentStep = 6 // iOS full: back to wallet
            } else {
                currentStep -= 1
            }
        }
    }

    /// Yes (restored) skips the relay import; No goes on to it as before.
    private func answerBackupQuestion(_ answer: VaultBackupQuestion.Answer) {
        guard let path = backupQuestionPath else { return }
        switch VaultBackupQuestion.next(after: answer, path: path) {
        case .finish:
            saveAndComplete()
        case .step(let next):
            direction = .forward
            withAnimation(WizardAnimations.springEnter) { currentStep = next }
            saveIntermediateConfig()
        }
    }

    private func saveIntermediateConfig() {
        configService.config.ownerNpub = npub
        // Browse / New to Nostr mode: set default localhost relay URL so the local relay can start
        configService.config.relayURL = ((setupPath == .browse || setupPath == .newToNostr || setupPath == .useNostr) && relayURL.isEmpty)
            ? "127.0.0.1:\(configService.config.relayPort)"
            : relayURL
        configService.config.dbEngine = "badger"
        configService.config.signingMode = setupPath == .newToNostr ? "local" : signingMode
        switch setupPath {
        case .browse: configService.config.setupMode = "browse"
        case .useNostr:
            // What was pasted decided it: a key or signer can post.
            configService.config.setupMode = useNostrIsReadOnly ? "browse" : "full"
        case .newToNostr:
            configService.config.setupMode = "newuser"
            // Following when people were picked. With none, FeedService's
            // no-follows path moves a new user to the curated Global feed;
            // Popular is the unfiltered one, which is why it isn't the default.
            configService.config.defaultFeedMode = "FOLLOWING"
            if configService.config.blossomMirrors.isEmpty {
                configService.config.blossomMirrors = HavenConfig.newAccountBlossomMirrors
            }
        default: configService.config.setupMode = "full"
        }
        configService.config.macRelayURL = macRelayURL
        configService.config.nwcURI = nwcURI

        if signingMode == "nip46" {
            configService.config.nip46BunkerURI = bunkerURI
        } else if !nsec.isEmpty && !nsecPassword.isEmpty {
            do {
                configService.config.ownerNcryptsec = try NIP49Service.encrypt(nsec: nsec, password: nsecPassword)
                configService.config.ownerNsec = ""
                _ = NIP49Service.storePasswordInKeychain(nsecPassword)
            } catch {
                setupError = "Failed to encrypt private key: \(error.localizedDescription)"
                showSetupError = true
                return
            }
        }
        configService.save()
    }

    private func saveAndComplete() {
        saveIntermediateConfig()
        configService.config.adoptGlobalBunkerConfigForOwner()
        configService.config.hasCompletedSetup = true
        // New accounts start with notifications on (DMs, replies, mentions and
        // zaps per NotificationPreferences' defaults) — otherwise a first DM
        // arrives silently. Set here rather than as the config default so
        // existing installs keep whatever they had.
        configService.config.enablePushNotifications = true
        configService.save()
        configService.refreshActiveAccountHex()

        // An existing account's DM inbox list (kind 10050) becomes this
        // device's. Setup doesn't publish one: the owner picks DM relays and
        // saves them in Settings > Relays (Logen 2026-10-31).
        Task { await NostrService.shared.adoptPublishedDMRelayList() }
        // An existing account's media servers (kind 10063) become upload servers.
        Task { await NostrService.shared.syncOwnerServerList() }

        if setupPath == .newToNostr {
            publishNewAccount()
        }

        // Who told you about Nostr Vault, and the people picked under them:
        // one follow-list edit, published once the list is known (a new key's
        // is empty; an existing key's is read first, so nothing is lost).
        let referralFollows = SetupReferral().takeFollows()
        if !referralFollows.isEmpty {
            FeedService.shared.followUsers(referralFollows)
        }

        if isIOSDevice {
            // Not on top of the first tutorial or the import pill: ask when
            // the first tutorial closes. If none does this launch,
            // AppDelegate asks at the next launch.
            TutorialCenter.shared.onNextClose = {
                PushNotificationService.shared.requestPermissionAndRegister()
            }
        } else {
            // The Mac asks as the setup window closes: the switch above is
            // already on, and without the system's permission nothing it
            // allows can show. The Mac AppDelegate asks again at launch.
            PushNotificationService.shared.requestPermissionAndRegister()
        }

        onComplete()
        dismiss()
    }

    /// The servers step 17 shows: this device's Write relays others can
    /// reach, so Change (Relays) updates it. By default the five starter
    /// relays, the same as the read relays (Logen 2026-10-31).
    private var starterRelays: [String] {
        RelayConfiguration.newAccountRelayListTags(
            broadcastRelays: RelayConfiguration.directBroadcastRelays(
                kind: 10002, tags: [], blastrRelays: configService.config.activeBlastrRelays
            )
        ).map { $0[1] }
            .filter { RelayDraft.listable($0) }
    }

    /// Publishes what a brand-new account needs to exist for other people:
    /// the relay list shown in step 17 (none when it was empty) and a profile. Its follow list starts with its first
    /// follow, in the Fill your feed guide. Runs once, after
    /// `saveAndComplete` has stored the key, because each event has to be
    /// signed by it. Only for the New to Nostr path, whose key was generated
    /// in this run — a key that cannot have any of these events yet.
    /// Both are signed as that key by name, not as whichever account is
    /// active when the photo upload (up to 30 s) finishes, and are dropped
    /// unless the signed pubkey is the new key's: a kind 0 or 10002 signed
    /// by another account would replace that account's own.
    private func publishNewAccount() {
        let ownerNpub = configService.config.ownerNpub
        guard let ownerHex = NpubValidation.hexPubkey(fromNpub: ownerNpub) else { return }
        FeedService.shared.markFreshAccount(ownerHex)
        // Straight into Fill your feed: this key follows nobody and can't
        // yet, so there is nothing to wait for (the follow-list check can
        // take 15s or more on slow relays, or never finish).
        FillYourVaultCoordinator.shared.start()
        TutorialCenter.shared.startIfEligible(.fillYourVault, account: ownerHex)
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = profilePhotoJPEG
        let configService = self.configService

        Task { @MainActor in
            let nostr = NostrService.shared

            // The list step 17 showed; empty there, nothing is published.
            let relayTags = RelayConfiguration.newAccountRelayListTags(broadcastRelays: starterRelayList ?? [])
            if !relayTags.isEmpty,
               let relayList = await nostr.signEventAsync(kind: 10002, content: "", tags: relayTags, signAsNpub: ownerNpub),
               relayList.pubkey.lowercased() == ownerHex.lowercased() {
                nostr.postEvent(relayList)
            }

            var profile: [String: Any] = [:]
            if !name.isEmpty {
                profile[ProfileMetadataMerge.name] = name
                profile[ProfileMetadataMerge.displayName] = name
            }
            if let photo {
                // The upload signs with this key and stores the blob in the
                // device's relay before mirroring it, so wait for the relay.
                // A photo that can't be hosted outside is left off rather
                // than published as a URL only this phone can serve.
                _ = await RelayProcessManager.shared.ensureRelayReady(timeout: 30)
                if let blob = try? await ModePostPublisher.upload(
                    data: photo, mimeType: "image/jpeg", configService: configService, nostrService: nostr
                ) {
                    profile[ProfileMetadataMerge.picture] = blob.url.absoluteString
                }
            }
            guard !profile.isEmpty,
                  let content = ProfileMetadataMerge.encode(profile),
                  let metadata = await nostr.signEventAsync(kind: 0, content: content, tags: [], signAsNpub: ownerNpub),
                  ProfileSaveGuard.mayPublish(kind: metadata.kind, signedPubkey: metadata.pubkey,
                                              profilePubkey: ownerHex, formLoadedFor: ownerHex) else { return }
            nostr.postEvent(metadata)
        }
    }

    private var processKillOverlay: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.appSystem(size: 48))
                    .foregroundColor(WizardColors.accentPrimary)

                VStack(spacing: 6) {
                    Text(String(localized: "relay.error.processKill.title"))
                        .font(.title2.bold())
                        .foregroundColor(WizardColors.textPrimary)

                    Text(String(localized: "relay.error.processKill.message"))
                        .multilineTextAlignment(.center)
                        .foregroundColor(WizardColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text("pkill -9 haven")
                        .font(.appSystem(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(WizardColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)

                    Button(action: {
                        #if os(macOS)
                        NSApp.activate(ignoringOtherApps: true)
                        #endif
                        PlatformClipboard.copy("pkill -9 haven")
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.appSystem(size: 14))
                            .foregroundColor(WizardColors.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(WizardColors.accentPrimary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    relayManager.showProcessKillAlert = false
                    relayManager.forceCleanAndRestart()
                }) {
                    Text(String(localized: "relay.error.processKill.retry"))
                        .font(.headline)
                        .foregroundColor(WizardColors.textPrimary)
                        .frame(width: 140, height: 36)
                        .background(WizardColors.accentPrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(30)
            .frame(width: 400)
            .background(WizardColors.bgCard)
            .cornerRadius(16)
            .transition(.scale.combined(with: .opacity))
        }
        .zIndex(100)
    }
}
