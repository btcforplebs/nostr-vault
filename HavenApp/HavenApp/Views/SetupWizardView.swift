import SwiftUI

// MARK: - Design System

enum WizardColors {
    static let bgPrimary = Color(red: 0.035, green: 0.035, blue: 0.043)      // #09090B
    static let bgCard = Color(red: 0.094, green: 0.094, blue: 0.106)          // #18181B
    static let bgElevated = Color(red: 0.153, green: 0.153, blue: 0.165)      // #27272A
    static let accentPrimary = Color(red: 0.961, green: 0.620, blue: 0.043)   // #F59E0B
    static let accentGlow = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.3)
    static let textPrimary = Color(red: 0.980, green: 0.980, blue: 0.980)     // #FAFAFA
    static let textSecondary = Color(red: 0.631, green: 0.631, blue: 0.667)   // #A1A1AA
    static let textMuted = Color(red: 0.443, green: 0.443, blue: 0.478)       // #71717A
    static let borderSubtle = Color(red: 0.153, green: 0.153, blue: 0.165)    // #27272A
    static let borderActive = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.5)
    static let success = Color(red: 0.133, green: 0.773, blue: 0.369)         // #22C55E
    static let error = Color(red: 0.937, green: 0.267, blue: 0.267)           // #EF4444

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.918, green: 0.345, blue: 0.047), Color(red: 0.961, green: 0.620, blue: 0.043)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// Onboarding runs slower than the rest of the app on purpose — it is the one
/// place the user is being walked through something rather than operating it.
/// These keep that tempo but route through `Motion.custom`, so the wizard's ~80
/// animation call sites pick up Reduce Motion without each one being touched.
enum WizardAnimations {
    static var springEnter: Animation { Motion.custom(response: 0.6, dampingFraction: 0.8) }
    static var springBounce: Animation { Motion.custom(response: 0.5, dampingFraction: 0.6) }
    static var springGentle: Animation { Motion.custom(response: 0.8, dampingFraction: 0.9) }
    static let fadeIn: Animation = .easeOut(duration: 0.4)
    static let staggerDelay: Double = 0.08
}

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

// MARK: - Shared Components

struct WizardPrimaryButton: View {
    let title: String
    let action: () -> Void
    var disabled: Bool = false

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .frame(maxWidth: isIOSDevice ? .infinity : nil, minHeight: 44)
                .padding(.horizontal, isIOSDevice ? 0 : 32)
                .background(WizardColors.accentGradient)
                .cornerRadius(12)
                .shadow(color: WizardColors.accentGlow, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .opacity(disabled ? 0.4 : 1.0)
        .disabled(disabled)
        .animation(WizardAnimations.springGentle, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

private struct WizardSkipLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(WizardColors.textMuted)
        }
        .buttonStyle(.plain)
    }
}

struct WizardGlassCard<Content: View>: View {
    var isSelected: Bool = false
    let content: () -> Content

    var body: some View {
        content()
            .padding(20)
            .background(WizardColors.bgCard)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? WizardColors.accentGlow : .clear, radius: 12)
    }
}

private struct WizardInputField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var isSecure: Bool = false
    var isDisabled: Bool = false
    /// When set (iOS only), a QR scan button is shown inside the field.
    var onScan: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(WizardColors.textSecondary)

            HStack(spacing: 8) {
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textPrimary)
                .focused($isFocused)
                .disabled(isDisabled)

                #if os(iOS)
                if let onScan {
                    Button(action: onScan) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 20))
                            .foregroundColor(WizardColors.accentPrimary)
                            .frame(width: 36, height: 36)
                            .background(WizardColors.bgElevated)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityLabel("Scan QR code")
                }
                #endif
            }
            .padding(12)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: isFocused ? 2 : 1)
            )
        }
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
    @State private var cashuMintURL = ""

    // Error state
    @State private var setupError: String?
    @State private var showSetupError = false

    let onComplete: () -> Void

    enum SetupPath {
        case none, full, browse, newToNostr
    }

    enum TransitionDirection {
        case forward, backward
    }

    // Compute visible steps based on path and platform
    private var totalVisibleSteps: Int {
        switch setupPath {
        case .none: return 3 // welcome, path, identity
        case .browse: return 4 // welcome, path, identity, import, done (4 dots, last = complete)
        case .newToNostr: return 5 // welcome, path, intro, follows, done
        case .full: return isIOSDevice ? 8 : 7  // welcome, path, identity, relay, import, media, wallet, (notif), done
        }
    }

    private var currentDotIndex: Int {
        // Map actual step numbers to dot indices
        let fullSteps: [Int] = isIOSDevice ? [0, 1, 2, 3, 4, 5, 6, 7, 8] : [0, 1, 2, 3, 4, 5, 6, 8]
        let browseSteps: [Int] = [0, 1, 2, 4, 8]
        let newUserSteps: [Int] = [0, 1, 9, 10, 8]
        let steps: [Int]
        switch setupPath {
        case .browse: steps = browseSteps
        case .newToNostr: steps = newUserSteps
        default: steps = fullSteps
        }
        return steps.firstIndex(of: currentStep) ?? 0
    }

    var body: some View {
        ZStack {
            // Full-screen dark background
            WizardColors.bgPrimary.ignoresSafeArea()

            // Ambient gradient
            AmbientGradientView()

            VStack(spacing: 0) {
                // Back button
                HStack {
                    if currentStep > 0 {
                        Button(action: goBack) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(String(localized: "setup.nav.back"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(WizardColors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
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
        case 0:
            WelcomeStepView(onContinue: { goForward() })
        case 1:
            ChoosePathStep(selectedPath: $setupPath, onContinue: { goForward() })
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
                cashuMintURL: $cashuMintURL,
                onContinue: {
                    if isIOSDevice {
                        goForward() // Go to notifications
                    } else {
                        currentStep = 8 // Go to complete
                    }
                },
                onSkip: {
                    if isIOSDevice {
                        goForward()
                    } else {
                        currentStep = 8
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
                nsecPassword: $nsecPassword,
                onContinue: {
                    saveIntermediateConfig()
                    direction = .forward
                    withAnimation(WizardAnimations.springEnter) {
                        currentStep = 10
                    }
                }
            )
        case 10:
            InitialFollowsStepView(
                onContinue: { selectedNpubs in
                    // Follow selected accounts
                    var currentFollows = configService.config.whitelistedNpubs
                    for npub in selectedNpubs where !currentFollows.contains(npub) {
                        currentFollows.append(npub)
                    }
                    configService.config.whitelistedNpubs = currentFollows
                    configService.save()

                    direction = .forward
                    withAnimation(WizardAnimations.springEnter) {
                        currentStep = 8
                    }
                },
                onSkip: {
                    direction = .forward
                    withAnimation(WizardAnimations.springEnter) {
                        currentStep = 8
                    }
                }
            )
        default:
            EmptyView()
        }
    }

    private func goForward() {
        direction = .forward
        withAnimation(WizardAnimations.springEnter) {
            if currentStep == 1 && setupPath == .newToNostr {
                // New to Nostr: go to intro step
                currentStep = 9
            } else if currentStep == 2 && setupPath == .browse {
                // Browse mode: skip relay config, go to import step
                currentStep = 4
            } else if currentStep == 4 && setupPath == .browse {
                // Browse mode: after import, skip mirror/wallet/notifications — go to complete
                currentStep = 8
            } else if currentStep == 6 && !isIOSDevice {
                // macOS full setup: skip notifications, go to complete
                currentStep = 8
            } else {
                currentStep += 1
            }
        }
        // Save intermediate config at key points
        if currentStep >= 3 || (currentStep == 8 && setupPath == .browse) || currentStep == 9 || currentStep == 10 {
            saveIntermediateConfig()
        }
    }

    private func goBack() {
        direction = .backward
        withAnimation(WizardAnimations.springEnter) {
            if currentStep == 9 {
                currentStep = 1 // New to Nostr: back to choose path
            } else if currentStep == 10 {
                currentStep = 9 // Initial Follows: back to intro
            } else if currentStep == 4 && setupPath == .browse {
                currentStep = 2 // Browse: back from import to identity (skip relay config)
            } else if currentStep == 8 {
                if setupPath == .newToNostr {
                    currentStep = 10 // New to Nostr: back to initial follows
                } else if setupPath == .browse {
                    currentStep = 4 // Browse: back to import
                } else if isIOSDevice {
                    currentStep = 7 // iOS full: back to notifications
                } else {
                    currentStep = 6 // macOS full: back to wallet
                }
            } else if currentStep == 7 && isIOSDevice {
                currentStep = 6 // iOS full: back to wallet
            } else {
                currentStep -= 1
            }
        }
    }

    private func saveIntermediateConfig() {
        configService.config.ownerNpub = npub
        // Browse / New to Nostr mode: set default localhost relay URL so the local relay can start
        configService.config.relayURL = ((setupPath == .browse || setupPath == .newToNostr) && relayURL.isEmpty)
            ? "127.0.0.1:\(configService.config.relayPort)"
            : relayURL
        configService.config.dbEngine = "badger"
        configService.config.signingMode = setupPath == .newToNostr ? "local" : signingMode
        switch setupPath {
        case .browse: configService.config.setupMode = "browse"
        case .newToNostr:
            configService.config.setupMode = "newuser"
            configService.config.defaultFeedMode = "POPULAR"
        default: configService.config.setupMode = "full"
        }
        configService.config.macRelayURL = macRelayURL
        configService.config.nwcURI = nwcURI
        configService.config.cashuMintURL = cashuMintURL

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
        configService.config.hasCompletedSetup = true
        configService.save()
        configService.refreshActiveAccountHex()

        // Advertise where to send us DMs. Setup never did this, so a new account
        // had no kind 10050 at all — anyone messaging them fell through to a
        // guessed relay set, and replies had nowhere defined to go. Without it a
        // brand-new user is effectively unreachable over NIP-17.
        NostrService.shared.republishDMRelayListsForSignableAccounts()

        if isIOSDevice {
            PushNotificationService.shared.requestPermissionAndRegister()
        }

        onComplete()
        dismiss()
    }

    private var processKillOverlay: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(WizardColors.accentPrimary)

                VStack(spacing: 6) {
                    Text(String(localized: "setup.error.processKill.title"))
                        .font(.title2.bold())
                        .foregroundColor(WizardColors.textPrimary)

                    Text(String(localized: "setup.error.processKill.message"))
                        .multilineTextAlignment(.center)
                        .foregroundColor(WizardColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text("pkill -9 haven")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
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
                            .font(.system(size: 14))
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
                    Text(String(localized: "setup.error.processKill.retry"))
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

// MARK: - Step 0: Welcome

private struct WelcomeStepView: View {
    let onContinue: () -> Void
    @State private var appeared = false

    private let features: [(icon: String, title: String, line: String)] = [
        ("externaldrive.connected.to.line.below", "Personal Relay", "Run your own relay on-device. Notes are stored locally and broadcast to the network — you always have a copy."),
        ("doc.text.image", "Full Nostr Client", "Browse your feed, post notes, reply, repost, and discover content from the network."),
        ("lock.shield", "Private Messaging", "NIP-17 encrypted DMs that stay on your device. No third-party server reads your conversations."),
        ("photo.stack", "Blossom Media", "Host images and videos on your machine with Blossom. Mirror media from the network to your local storage."),
        ("bolt.fill", "Lightning + Ecash", "Send and receive zaps over Lightning with NWC. Store ecash tokens with a built-in Cashu wallet.")
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 20)

            // App icon
            Image(systemName: "shield.checkered")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(WizardColors.accentGradient)
                .scaleEffect(appeared ? 1.0 : 0.8)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.springEnter, value: appeared)

            // Title
            Text(String(localized: "setup.welcome.appName"))
                .font(.system(size: isIOSDevice ? 32 : 36, weight: .bold, design: .default))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

            // Subtitle lines
            VStack(spacing: 6) {
                Text(String(localized: "setup.welcome.subtitle1"))
                Text(String(localized: "setup.welcome.subtitle2"))
            }
            .font(.system(size: isIOSDevice ? 15 : 16))
            .foregroundColor(WizardColors.textSecondary)
            .multilineTextAlignment(.center)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            // Feature cards
            VStack(spacing: 10) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    featureCard(icon: feature.icon, title: feature.title, line: feature.line)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(WizardAnimations.springEnter.delay(0.6 + Double(index) * WizardAnimations.staggerDelay), value: appeared)
                }
            }

            // CTA
            WizardPrimaryButton(title: String(localized: "setup.welcome.getStarted"), action: onContinue)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(1.0), value: appeared)

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }

    private func featureCard(icon: String, title: String, line: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(WizardColors.accentPrimary)
                .shadow(color: WizardColors.accentGlow, radius: 4)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: isIOSDevice ? 15 : 16, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                Text(line)
                    .font(.system(size: isIOSDevice ? 13 : 14))
                    .foregroundColor(WizardColors.textSecondary)
            }

            Spacer()
        }
        .padding(14)
        .background(WizardColors.bgCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(WizardColors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Step 1: Choose Path

private struct ChoosePathStep: View {
    @Binding var selectedPath: SetupWizardView.SetupPath
    let onContinue: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 40)

            Text(String(localized: "setup.path.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            VStack(spacing: 14) {
                // New to Nostr card
                Button(action: { withAnimation(WizardAnimations.springEnter) { selectedPath = .newToNostr } }) {
                    WizardGlassCard(isSelected: selectedPath == .newToNostr) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 28))
                                .foregroundColor(selectedPath == .newToNostr ? WizardColors.accentPrimary : WizardColors.textSecondary)
                                .frame(width: 36)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("New to Nostr")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(WizardColors.textPrimary)
                                    Spacer()
                                    if selectedPath == .newToNostr {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(WizardColors.accentPrimary)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                Text("Quick start -- we'll set everything up for you")
                                    .font(.system(size: 14))
                                    .foregroundColor(WizardColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .opacity(selectedPath != .none && selectedPath != .newToNostr ? 0.7 : 1.0)
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

                // Full Setup card
                Button(action: { withAnimation(WizardAnimations.springEnter) { selectedPath = .full } }) {
                    WizardGlassCard(isSelected: selectedPath == .full) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 28))
                                .foregroundColor(selectedPath == .full ? WizardColors.accentPrimary : WizardColors.textSecondary)
                                .frame(width: 36)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(String(localized: "setup.path.full.title"))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(WizardColors.textPrimary)
                                    Spacer()
                                    if selectedPath == .full {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(WizardColors.accentPrimary)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                Text(String(localized: "setup.path.full.description"))
                                    .font(.system(size: 14))
                                    .foregroundColor(WizardColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .opacity(selectedPath != .none && selectedPath != .full ? 0.7 : 1.0)
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

                // Browse Mode card
                Button(action: { withAnimation(WizardAnimations.springEnter) { selectedPath = .browse } }) {
                    WizardGlassCard(isSelected: selectedPath == .browse) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 28))
                                .foregroundColor(selectedPath == .browse ? WizardColors.accentPrimary : WizardColors.textSecondary)
                                .frame(width: 36)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(String(localized: "setup.path.browse.title"))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(WizardColors.textPrimary)
                                    Spacer()
                                    if selectedPath == .browse {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(WizardColors.accentPrimary)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                Text(String(localized: "setup.path.browse.description"))
                                    .font(.system(size: 14))
                                    .foregroundColor(WizardColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .opacity(selectedPath != .none && selectedPath != .browse ? 0.7 : 1.0)
                }
                .buttonStyle(.plain)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)
            }

            if selectedPath != .none {
                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Step 9: Nostr Intro (New to Nostr path)

private struct NostrIntroStep: View {
    @Binding var npub: String
    @Binding var nsec: String
    @Binding var nsecPassword: String
    let onContinue: () -> Void

    @State private var appeared = false
    @State private var generatedKeys = false
    @State private var isGenerating = false
    @State private var error: String?
    @State private var keyPassword = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            // Card 1: What is Nostr
            WizardGlassCard(isSelected: false) {
                VStack(spacing: 12) {
                    Text("Welcome to Nostr")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Nostr is an open social protocol. You own your identity through a cryptographic keypair -- no company controls your account. Your posts are broadcast to relays and can be read by anyone.")
                        .font(.system(size: 15))
                        .foregroundColor(WizardColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(WizardAnimations.springEnter.delay(0.15), value: appeared)

            // Card 2: Why Nostr Vault is unique
            WizardGlassCard(isSelected: false) {
                VStack(spacing: 12) {
                    Text("Your Personal Archive")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Nostr Vault runs a HAVEN relay right on your device. Every note, message, and media file you interact with is archived locally. Your data stays with you -- not on someone else's server.")
                        .font(.system(size: 15))
                        .foregroundColor(WizardColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

            if generatedKeys {
                // Card 3: Secret key backup
                WizardGlassCard(isSelected: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Secret Key")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)

                        Text("Save this somewhere safe. It's the only way to recover your account. Anyone with this key can post as you.")
                            .font(.system(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                            .lineSpacing(2)

                        Button {
                            #if os(iOS)
                            UIPasteboard.general.string = nsec
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(nsec, forType: .string)
                            #endif
                        } label: {
                            Text(nsec)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(WizardColors.accentPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(WizardColors.bgElevated)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(WizardColors.borderSubtle, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Text("Tap to copy")
                            .font(.system(size: 11))
                            .foregroundColor(WizardColors.textMuted)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))

                // Card 4: Password protection
                WizardGlassCard(isSelected: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Protect Your Key")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)

                        Text("Set a password to encrypt your private key. You'll need this password to use Haven.")
                            .font(.system(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                            .lineSpacing(2)

                        VStack(spacing: 10) {
                            HStack {
                                if showPassword {
                                    TextField("Password (minimum 8 characters)", text: $keyPassword)
                                        .font(.system(size: 14))
                                        .foregroundColor(WizardColors.textPrimary)
                                        .textFieldStyle(.plain)
                                        .disableAutocorrection(true)
                                } else {
                                    SecureField("Password (minimum 8 characters)", text: $keyPassword)
                                        .font(.system(size: 14))
                                        .foregroundColor(WizardColors.textPrimary)
                                        .textFieldStyle(.plain)
                                        .disableAutocorrection(true)
                                }
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .font(.system(size: 14))
                                        .foregroundColor(WizardColors.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(WizardColors.bgElevated)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(WizardColors.borderSubtle, lineWidth: 1)
                            )

                            if showPassword {
                                TextField("Confirm password", text: $confirmPassword)
                                    .font(.system(size: 14))
                                    .foregroundColor(WizardColors.textPrimary)
                                    .textFieldStyle(.plain)
                                    .disableAutocorrection(true)
                                    .padding(12)
                                    .background(WizardColors.bgElevated)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(WizardColors.borderSubtle, lineWidth: 1)
                                    )
                            } else {
                                SecureField("Confirm password", text: $confirmPassword)
                                    .font(.system(size: 14))
                                    .foregroundColor(WizardColors.textPrimary)
                                    .textFieldStyle(.plain)
                                    .disableAutocorrection(true)
                                    .padding(12)
                                    .background(WizardColors.bgElevated)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(WizardColors.borderSubtle, lineWidth: 1)
                                    )
                            }
                        }

                        if !keyPassword.isEmpty && keyPassword.count < 8 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 12))
                                Text("Password must be at least 8 characters")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(WizardColors.error)
                        }

                        if !confirmPassword.isEmpty && keyPassword != confirmPassword {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 12))
                                Text("Passwords do not match")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(WizardColors.error)
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))

                WizardPrimaryButton(title: "Continue", action: validateAndContinue)
                    .disabled(!isPasswordValid)
                    .opacity(isPasswordValid ? 1.0 : 0.5)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                if let errorText = error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text(errorText)
                            .font(.system(size: 13))
                    }
                    .foregroundColor(WizardColors.error)
                }

                WizardPrimaryButton(title: "Create My Account", action: generateKeys)
                    .disabled(isGenerating)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(WizardAnimations.springEnter.delay(0.45), value: appeared)

                if isGenerating {
                    ProgressView()
                        .tint(WizardColors.accentPrimary)
                }
            }

            Spacer()
        }
        .onAppear { appeared = true }
    }

    private func generateKeys() {
        isGenerating = true
        error = nil

        guard let resultCStr = GenerateKeyPairC() else {
            error = "Key generation failed"
            isGenerating = false
            return
        }
        let result = String(cString: resultCStr)
        let parts = result.split(separator: ":")
        guard parts.count == 2 else {
            error = "Key generation returned invalid format"
            isGenerating = false
            return
        }
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
        isGenerating = false
    }

    private var isPasswordValid: Bool {
        !keyPassword.isEmpty && keyPassword.count >= 8 && keyPassword == confirmPassword
    }

    private func validateAndContinue() {
        guard isPasswordValid else { return }
        nsecPassword = keyPassword
        onContinue()
    }
}

// MARK: - Step 2: Identity

private struct IdentityStepView: View {
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
        guard let decoded = Bech32.decode(npub), decoded.hrp == "npub" else { return false }
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
        if !nsec.isEmpty && nsecPassword.isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(isBrowseMode ? String(localized: "setup.identity.title.browse") : String(localized: "setup.identity.title.full"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            if isBrowseMode {
                Text("Enter your npub, NIP-05 (user@domain), or scan a QR code.")
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)
            }

            if isBrowseMode {
                // Browse mode: unified identity input (npub / NIP-05 / QR)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Identity")
                        .font(.system(size: 13))
                        .foregroundColor(WizardColors.textSecondary)

                    HStack(spacing: 8) {
                        TextField("npub1... or user@domain.com", text: $identityInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
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
                                    // Decode nprofile TLV to extract pubkey
                                    if let decoded = Bech32.decode(cleaned), decoded.hrp == "nprofile" {
                                        let bytes = Array(decoded.data)
                                        var i = 0
                                        while i + 2 <= bytes.count {
                                            let type = bytes[i]
                                            let length = Int(bytes[i + 1])
                                            i += 2
                                            if i + length > bytes.count { break }
                                            if type == 0 && length == 32 {
                                                let pubkeyHex = bytes[i..<i+length].map { String(format: "%02x", $0) }.joined()
                                                if let pubData = Bech32.hexToData(pubkeyHex),
                                                   let resolvedNpub = Bech32.encode(hrp: "npub", data: pubData) {
                                                    npub = resolvedNpub
                                                }
                                            }
                                            i += length
                                        }
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
                                .font(.system(size: 20))
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
                            .font(.system(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                    }
                } else if let resolved = resolvedFromNIP05 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(WizardColors.success)
                        Text("Resolved: \(String(resolved.prefix(20)))...")
                            .font(.system(size: 13))
                            .foregroundColor(WizardColors.success)
                    }
                } else if let error = nip05Error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text(error)
                            .font(.system(size: 13))
                    }
                    .foregroundColor(WizardColors.error)
                } else if !identityInput.isEmpty && !isNpubValid && !looksLikeNIP05 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text("Enter a valid npub or NIP-05 identifier")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(WizardColors.error)
                } else if isNpubValid && !identityInput.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(WizardColors.success)
                        Text("Valid public key")
                            .font(.system(size: 13))
                            .foregroundColor(WizardColors.success)
                    }
                }
            } else {
                // Full mode: standard npub field
                WizardInputField(label: String(localized: "setup.identity.label.npub"), text: $npub, placeholder: "npub1...", isDisabled: selectedMethod == .nip46 && bunkerConnected)
                    .opacity(appeared ? 1 : 0)
                    .offset(x: appeared ? 0 : 20)
                    .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

                if !npub.isEmpty && !isNpubValid {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text(String(localized: "setup.identity.invalidNpub"))
                            .font(.system(size: 13))
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

                        if !nsec.isEmpty && !nsec.hasPrefix("nsec") {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                Text(String(localized: "setup.identity.invalidNsec"))
                                    .font(.system(size: 13))
                            }
                            .foregroundColor(WizardColors.error)
                        }

                        if !nsec.isEmpty {
                            WizardInputField(label: String(localized: "setup.identity.label.password"), text: $nsecPassword, placeholder: "Enter password...", isSecure: true)
                                .transition(.move(edge: .top).combined(with: .opacity))

                            Text(String(localized: "setup.identity.passwordHint"))
                                .font(.system(size: 12))
                                .foregroundColor(WizardColors.textMuted)

                            if nsecPassword.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.caption)
                                    Text(String(localized: "setup.identity.passwordRequired"))
                                        .font(.system(size: 13))
                                }
                                .foregroundColor(WizardColors.accentPrimary)
                            }
                        }

                        Button(action: generateNewIdentity) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(WizardColors.accentPrimary)
                                Text(String(localized: "setup.identity.generateKeys"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(WizardColors.accentPrimary)
                            }
                        }
                        .buttonStyle(.plain)

                        if generatedKeys {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundColor(WizardColors.accentPrimary)
                                Text(String(localized: "setup.identity.nsecWarning"))
                                    .font(.system(size: 13))
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
                        WizardInputField(
                            label: String(localized: "setup.identity.label.bunker"),
                            text: $bunkerURI,
                            placeholder: "bunker://...",
                            isDisabled: bunkerConnected,
                            onScan: { activeScanner = .bunker }
                        )

                        Text(String(localized: "setup.identity.bunkerHint"))
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)

                        if let error = bunkerError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                Text(error)
                                    .font(.system(size: 13))
                            }
                            .foregroundColor(WizardColors.error)
                        }

                        if bunkerConnected {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(WizardColors.success)
                                Text(String(localized: "setup.identity.bunkerConnected"))
                                    .font(.system(size: 13))
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
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? WizardColors.accentPrimary : WizardColors.textSecondary)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)

                Text(subtitle)
                    .font(.system(size: 12))
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

                try await NIP46Service.shared.connect()
                let pubkey = try await NIP46Service.shared.getPublicKey()

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

// MARK: - Step 3: Relay Configuration

private struct RelayConfigStep: View {
    @Binding var relayURL: String
    @Binding var macRelayURL: String
    let onContinue: () -> Void
    let onSkip: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            #if os(macOS)
            macOSRelayContent
            #else
            iOSRelayContent
            #endif

            WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.relay.skip")) {
                onSkip()
            }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }

    // MARK: macOS variant
    private var macOSRelayContent: some View {
        VStack(spacing: 20) {
            Text(String(localized: "setup.relay.mac.title"))
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            // Network diagram
            RelayDiagramMac(hasURL: !relayURL.isEmpty)
                .frame(height: 160)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            VStack(spacing: 8) {
                Text(String(localized: "setup.relay.mac.description1"))
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)

                Text(String(localized: "setup.relay.mac.description2"))
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            WizardInputField(label: String(localized: "setup.relay.mac.label"), text: $relayURL, placeholder: "relay.yourdomain.com")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            Text(String(localized: "setup.relay.mac.hint"))
                .font(.system(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
    }

    // MARK: iOS variant
    private var iOSRelayContent: some View {
        VStack(spacing: 20) {
            Text(String(localized: "setup.relay.ios.title"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            // Network diagram
            RelayDiagramiOS(hasURL: !macRelayURL.isEmpty)
                .frame(height: 120)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            VStack(spacing: 8) {
                Text(String(localized: "setup.relay.ios.description1"))
                    .font(.system(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)

                Text(String(localized: "setup.relay.ios.description2"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            WizardInputField(label: String(localized: "setup.relay.ios.label"), text: $macRelayURL, placeholder: "wss://relay.yourdomain.com")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            Text(String(localized: "setup.relay.ios.hint"))
                .font(.system(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
    }
}

// MARK: - Relay Diagrams

private struct RelayDiagramMac: View {
    let hasURL: Bool
    @State private var particlePhase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let centerX = size.width / 2
                let centerY = size.height / 2

                // Mac icon position
                let macX = centerX - 80
                let macY = centerY

                // Relay position
                let relayX = centerX
                let relayY = centerY + 40

                // Network position
                let netX = centerX + 100
                let netY = centerY - 10

                // Draw connection lines
                drawLine(context: context, from: CGPoint(x: macX, y: macY), to: CGPoint(x: relayX, y: relayY), color: WizardColors.accentPrimary.opacity(0.4))
                drawLine(context: context, from: CGPoint(x: relayX, y: relayY), to: CGPoint(x: netX, y: netY), color: WizardColors.accentPrimary.opacity(0.3))

                // Draw flowing particle
                let particleT = fmod(t * 0.3, 1.0)
                let px = macX + (netX - macX) * particleT
                let py = macY + (netY - macY) * particleT
                let particleRect = CGRect(x: px - 3, y: py - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: particleRect), with: .color(WizardColors.accentPrimary))

                // Globe connection when URL entered
                if hasURL {
                    let globeX = relayX
                    let globeY = centerY - 40
                    drawLine(context: context, from: CGPoint(x: relayX, y: relayY), to: CGPoint(x: globeX, y: globeY), color: WizardColors.accentPrimary.opacity(0.3))
                }

                // Network dots
                for i in 0..<6 {
                    let angle = Double(i) * (.pi * 2.0 / 6.0) + t * 0.05
                    let dx = netX + cos(angle) * 25
                    let dy = netY + sin(angle) * 25
                    let brightness = 0.3 + 0.2 * sin(t * 0.5 + Double(i))
                    let dotRect = CGRect(x: dx - 3, y: dy - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dotRect), with: .color(WizardColors.textMuted.opacity(brightness)))
                }
            }
            .overlay {
                // SF Symbol overlays
                VStack {
                    HStack(spacing: 80) {
                        VStack(spacing: 4) {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 32))
                                .foregroundColor(WizardColors.textPrimary)
                                .shadow(color: WizardColors.accentGlow, radius: 6)
                            Text(String(localized: "setup.relay.diagram.mac"))
                                .font(.system(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -8)

                        VStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.system(size: 24))
                                .foregroundColor(WizardColors.textMuted)
                            Text(String(localized: "setup.relay.diagram.network"))
                                .font(.system(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -20)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 16))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.relay.diagram.relay"))
                            .font(.system(size: 11))
                            .foregroundColor(WizardColors.accentPrimary)
                    }
                    .offset(y: 8)

                    if hasURL {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 14))
                                .foregroundColor(WizardColors.accentPrimary.opacity(0.7))
                            Text(String(localized: "setup.relay.diagram.public"))
                                .font(.system(size: 10))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -50)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private func drawLine(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}

private struct RelayDiagramiOS: View {
    let hasURL: Bool

    var body: some View {
        HStack(spacing: 0) {
            // iPhone
            VStack(spacing: 4) {
                Image(systemName: "iphone")
                    .font(.system(size: 28))
                    .foregroundColor(WizardColors.textPrimary)
                Text(String(localized: "setup.relay.diagram.iphone"))
                    .font(.system(size: 11))
                    .foregroundColor(WizardColors.textMuted)
            }

            // Connection line
            VStack(spacing: 2) {
                Rectangle()
                    .fill(hasURL ? WizardColors.accentPrimary.opacity(0.5) : WizardColors.textMuted.opacity(0.3))
                    .frame(height: 2)
                    .overlay {
                        if !hasURL {
                            // Dashed line
                            Rectangle()
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .foregroundColor(WizardColors.textMuted.opacity(0.4))
                        }
                    }
                if !hasURL {
                    Text("?")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(WizardColors.textMuted)
                }
            }
            .frame(width: 60)

            // Mac + Relay
            VStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 28))
                    .foregroundColor(hasURL ? WizardColors.textPrimary : WizardColors.textMuted)
                    .shadow(color: hasURL ? WizardColors.accentGlow : .clear, radius: 4)
                HStack(spacing: 2) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 10))
                    Text(String(localized: "setup.relay.diagram.macRelay"))
                        .font(.system(size: 11))
                }
                .foregroundColor(hasURL ? WizardColors.accentPrimary : WizardColors.textMuted)
            }

            // Connection to network
            Rectangle()
                .fill(WizardColors.textMuted.opacity(0.3))
                .frame(width: 40, height: 2)

            // Network
            VStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 24))
                    .foregroundColor(WizardColors.textMuted)
                Text(String(localized: "setup.relay.diagram.nostr"))
                    .font(.system(size: 11))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
        .padding(.vertical, 16)
    }
}

// MARK: - Step 4: Import Notes

private struct ImportNotesStep: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var activeTab = 0 // 0 = Network, 1 = Backup
    @State private var showingFileImporter = false
    @State private var isRestoring = false
    @State private var restoreCompleted = false
    @State private var restoreError: String?
    @State private var showRestoreError = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.import.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.import.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Tab bar
            HStack(spacing: 4) {
                tabPill(String(localized: "setup.import.tab.network"), isActive: activeTab == 0) { activeTab = 0 }
                tabPill(String(localized: "setup.import.tab.backup"), isActive: activeTab == 1) { activeTab = 1 }
            }
            .padding(3)
            .background(WizardColors.bgCard)
            .cornerRadius(10)
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.25), value: appeared)

            // Tab content
            Group {
                if activeTab == 0 {
                    networkImportContent
                } else {
                    backupRestoreContent
                }
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            WizardSkipLink(title: String(localized: "setup.import.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                restoreBackup(from: url)
            case .failure(let error):
                restoreError = error.localizedDescription
                showRestoreError = true
            }
        }
        .alert(String(localized: "setup.import.alert.restoreFailed"), isPresented: $showRestoreError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(restoreError ?? "Unknown error")
        }
        .alert(String(localized: "setup.import.alert.portConflict"), isPresented: $relayManager.isPortConflict) {
            Button(String(localized: "setup.import.alert.retry")) {
                relayManager.isPortConflict = false
                relayManager.importNotes(config: configService.config)
            }
            Button(String(localized: "setup.action.cancel"), role: .cancel) {
                relayManager.isPortConflict = false
                relayManager.cancelImport()
            }
        } message: {
            Text("Port \(configService.config.relayPort) is currently in use. Stop the other process or change the port in Settings.")
        }
    }

    @ViewBuilder
    private var networkImportContent: some View {
        VStack(spacing: 14) {
            if relayManager.isImporting || relayManager.importCompleted {
                VStack(spacing: 12) {
                    HStack {
                        Text(relayManager.importCompleted ? String(localized: "setup.import.done") : String(localized: "setup.import.importing"))
                            .font(.system(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                        Spacer()
                        Text("\(Int(relayManager.importProgress * 100))%")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(WizardColors.accentPrimary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(WizardColors.bgElevated)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(WizardColors.accentGradient)
                                .frame(width: geo.size.width * relayManager.importProgress, height: 6)
                        }
                    }
                    .frame(height: 6)

                    if !relayManager.importCompleted {
                        Text(relayManager.importStatusMessage)
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                            .lineLimit(2)
                    }

                    if relayManager.importCompleted {
                        WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
                    } else {
                        Button(action: { relayManager.cancelImport() }) {
                            Text(String(localized: "setup.import.cancelImport"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(WizardColors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker(String(localized: "setup.import.startDate"), selection: Binding(
                        get: {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            return formatter.date(from: configService.config.importStartDate) ?? Date()
                        },
                        set: {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            configService.config.importStartDate = formatter.string(from: $0)
                        }
                    ), displayedComponents: .date)
                    .font(.system(size: 14))
                    .foregroundColor(WizardColors.textPrimary)
                    .colorScheme(.dark)

                    Divider().background(WizardColors.borderSubtle)

                    Text(String(localized: "setup.import.seedRelays"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)

                    RelayListEditor(relays: $configService.config.importSeedRelays)
                        .frame(minHeight: 80, maxHeight: 120)
                        .cornerRadius(8)
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))

                WizardPrimaryButton(title: String(localized: "setup.import.action")) {
                    configService.save()
                    relayManager.importNotes(config: configService.config)
                }
            }
        }
    }

    @ViewBuilder
    private var backupRestoreContent: some View {
        VStack(spacing: 14) {
            if isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(WizardColors.accentPrimary)
                    Text(String(localized: "setup.import.restoring"))
                        .font(.system(size: 14))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if restoreCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(String(localized: "setup.import.restoreSuccess"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                Button(action: {
                    #if os(macOS)
                    NSApp.activate(ignoringOtherApps: true)
                    #endif
                    showingFileImporter = true
                }) {
                    HStack {
                        Image(systemName: "doc.zipper")
                            .font(.title3)
                        Text(String(localized: "setup.import.chooseBackup"))
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(WizardColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(WizardColors.bgCard)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                            .foregroundColor(WizardColors.borderSubtle)
                    )
                }
                .buttonStyle(.plain)

                Text(String(localized: "setup.import.backupHint"))
                    .font(.system(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
    }

    private func restoreBackup(from url: URL) {
        isRestoring = true
        guard url.startAccessingSecurityScopedResource() else {
            restoreError = "Permission denied to access the file."
            showRestoreError = true
            isRestoring = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { safeURL in
            do {
                if FileManager.default.fileExists(atPath: tempFile.path) {
                    try FileManager.default.removeItem(at: tempFile)
                }
                try FileManager.default.copyItem(at: safeURL, to: tempFile)
            } catch {
                copyError = error
            }
        }

        if let error = coordinationError ?? copyError {
            restoreError = "Failed to copy backup file: \(error.localizedDescription)"
            showRestoreError = true
            isRestoring = false
            return
        }

        configService.save()
        RelayProcessManager.shared.runBackupRestore(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)
            Task { @MainActor in
                isRestoring = false
                if success {
                    configService.reload()
                    restoreCompleted = true
                } else {
                    restoreError = "Failed to restore backup. Check logs for details."
                    showRestoreError = true
                }
            }
        }
    }
}

// MARK: - Step 5: Mirror Media

private struct MirrorMediaStep: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var activeTab = 0
    @State private var blossomURL = "https://blossom.primal.net"
    @State private var showingFileImporter = false
    @State private var isSyncing = false
    @State private var syncCompleted = false
    @State private var syncError: String?
    @State private var showSyncError = false
    @State private var progressMessage = ""
    @State private var progressValue: Double = 0
    @State private var syncedCount = 0
    @State private var totalCount = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.media.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.media.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Tab bar
            HStack(spacing: 4) {
                tabPill(String(localized: "setup.media.tab.server"), isActive: activeTab == 0) { activeTab = 0 }
                tabPill(String(localized: "setup.media.tab.backup"), isActive: activeTab == 1) { activeTab = 1 }
            }
            .padding(3)
            .background(WizardColors.bgCard)
            .cornerRadius(10)
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.25), value: appeared)

            Group {
                if activeTab == 0 {
                    serverSyncContent
                } else {
                    backupImportContent
                }
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            WizardSkipLink(title: String(localized: "setup.media.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importMedia(from: url)
            case .failure(let error):
                syncError = error.localizedDescription
                showSyncError = true
            }
        }
        .alert(String(localized: "setup.media.alert.importFailed"), isPresented: $showSyncError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(syncError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var serverSyncContent: some View {
        VStack(spacing: 14) {
            if isSyncing {
                VStack(spacing: 16) {
                    // Circular progress
                    ZStack {
                        Circle()
                            .stroke(WizardColors.bgElevated, lineWidth: 6)
                            .frame(width: 80, height: 80)
                        Circle()
                            .trim(from: 0, to: progressValue)
                            .stroke(WizardColors.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(WizardAnimations.springGentle, value: progressValue)

                        Text("\(syncedCount) / \(totalCount)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(WizardColors.textPrimary)
                    }

                    Text(progressMessage.isEmpty ? String(localized: "setup.media.syncing") : progressMessage)
                        .font(.system(size: 13))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if syncCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(progressMessage.isEmpty ? String(localized: "setup.media.syncSuccess") : progressMessage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                WizardInputField(label: String(localized: "setup.media.label.blossomURL"), text: $blossomURL, placeholder: "https://blossom.primal.net")

                WizardPrimaryButton(title: String(localized: "setup.media.syncAction")) {
                    startNetworkSync()
                }
            }
        }
    }

    @ViewBuilder
    private var backupImportContent: some View {
        VStack(spacing: 14) {
            if isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(WizardColors.accentPrimary)
                    Text(String(localized: "setup.media.importing"))
                        .font(.system(size: 14))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if syncCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(String(localized: "setup.media.importSuccess"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                Button(action: {
                    #if os(macOS)
                    NSApp.activate(ignoringOtherApps: true)
                    #endif
                    showingFileImporter = true
                }) {
                    HStack {
                        Image(systemName: "doc.zipper")
                            .font(.title3)
                        Text(String(localized: "setup.media.chooseArchive"))
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(WizardColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(WizardColors.bgCard)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                            .foregroundColor(WizardColors.borderSubtle)
                    )
                }
                .buttonStyle(.plain)

                Text(String(localized: "setup.media.backupHint"))
                    .font(.system(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
    }

    private func startNetworkSync() {
        isSyncing = true
        progressMessage = "Connecting..."
        progressValue = 0
        syncedCount = 0
        totalCount = 0

        let trimmedURL = blossomURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let _ = URL(string: trimmedURL) else {
            syncError = "Invalid Blossom server URL."
            showSyncError = true
            isSyncing = false
            return
        }

        if !configService.config.blossomMirrors.contains(trimmedURL) {
            configService.config.blossomMirrors.append(trimmedURL)
            configService.save()
            NostrService.shared.publishServerList()
        }

        Task {
            let blossomService = BlossomService(configService: configService, nostrService: nostrService)
            let mirroredCount = await blossomService.mirrorAllFromExternal { completed, total in
                syncedCount = completed
                totalCount = total
                progressValue = total > 0 ? Double(completed) / Double(total) : 0
                progressMessage = "Mirrored \(completed) of \(total) files..."
            }

            isSyncing = false
            syncCompleted = true
            progressMessage = "Synced \(mirroredCount) files."
        }
    }

    private func importMedia(from url: URL) {
        isSyncing = true
        guard url.startAccessingSecurityScopedResource() else {
            syncError = "Permission denied to access the file."
            showSyncError = true
            isSyncing = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try FileManager.default.removeItem(at: tempFile)
            }
            try FileManager.default.copyItem(at: url, to: tempFile)
        } catch {
            syncError = "Failed to copy media archive: \(error.localizedDescription)"
            showSyncError = true
            isSyncing = false
            return
        }

        RelayProcessManager.shared.runBlossomImportStrippingExtensions(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)
            Task { @MainActor in
                isSyncing = false
                if success {
                    syncCompleted = true
                } else {
                    syncError = "Failed to import media. Check logs for details."
                    showSyncError = true
                }
            }
        }
    }
}

// MARK: - Step 6: Wallet Setup

private struct WalletSetupStep: View {
    @Binding var nwcURI: String
    @Binding var cashuMintURL: String
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var lightningExpanded = false
    @State private var cashuExpanded = false
    @State private var nwcStatus: ConnectionStatus = .idle

    enum ConnectionStatus {
        case idle, testing, connected, failed
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.wallet.title"))
                .font(.system(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.wallet.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Lightning (NWC) section
            VStack(spacing: 0) {
                Button(action: { withAnimation(WizardAnimations.springEnter) { lightningExpanded.toggle() } }) {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 18))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.wallet.lightning.title"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                        Spacer()
                        Image(systemName: lightningExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)

                if lightningExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().background(WizardColors.borderSubtle)

                        WizardInputField(label: String(localized: "setup.wallet.lightning.label"), text: $nwcURI, placeholder: "nostr+walletconnect://...")

                        Text(String(localized: "setup.wallet.lightning.hint"))
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)

                        // Connection status
                        if nwcStatus == .testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(WizardColors.accentPrimary)
                                Text(String(localized: "setup.wallet.lightning.connecting"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.textSecondary)
                            }
                        } else if nwcStatus == .connected {
                            HStack(spacing: 6) {
                                Circle().fill(WizardColors.success).frame(width: 8, height: 8)
                                Text(String(localized: "setup.wallet.lightning.connected"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.success)
                            }
                        } else if nwcStatus == .failed {
                            HStack(spacing: 6) {
                                Circle().fill(WizardColors.error).frame(width: 8, height: 8)
                                Text(String(localized: "setup.wallet.lightning.failed"))
                                    .font(.system(size: 13))
                                    .foregroundColor(WizardColors.error)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

            // Cashu Ecash section
            VStack(spacing: 0) {
                Button(action: { withAnimation(WizardAnimations.springEnter) { cashuExpanded.toggle() } }) {
                    HStack {
                        Image(systemName: "centsign.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.wallet.cashu.title"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                        Spacer()
                        Image(systemName: cashuExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)

                if cashuExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().background(WizardColors.borderSubtle)

                        WizardInputField(label: String(localized: "setup.wallet.cashu.label"), text: $cashuMintURL, placeholder: "https://mint.example.com")

                        Text(String(localized: "setup.wallet.cashu.hint"))
                            .font(.system(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.38), value: appeared)

            WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.wallet.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Step 6b: Push Notifications (iOS only)

private struct PushNotificationStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void
    @State private var appeared = false
    @State private var dmEnabled = true
    @State private var zapEnabled = true
    @State private var mentionEnabled = true

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 40)

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56))
                .foregroundColor(WizardColors.accentPrimary)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .offset(y: appeared ? 0 : -20)
                .animation(WizardAnimations.springBounce.delay(0.1), value: appeared)

            Text(String(localized: "setup.notifications.title"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            Text(String(localized: "setup.notifications.subtitle"))
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.4), value: appeared)

            // Toggle cards
            VStack(spacing: 0) {
                notificationToggle(icon: "bubble.left.fill", label: String(localized: "setup.notifications.directMessages"), isOn: $dmEnabled)
                Divider().background(WizardColors.borderSubtle).padding(.horizontal, 16)
                notificationToggle(icon: "bolt.fill", label: String(localized: "setup.notifications.zaps"), isOn: $zapEnabled)
                Divider().background(WizardColors.borderSubtle).padding(.horizontal, 16)
                notificationToggle(icon: "at", label: String(localized: "setup.notifications.mentions"), isOn: $mentionEnabled)
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.5), value: appeared)

            WizardPrimaryButton(title: String(localized: "setup.notifications.enable"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.notifications.skip")) { onSkip() }

            Spacer()
        }
        .onAppear { appeared = true }
    }

    private func notificationToggle(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .tint(WizardColors.accentPrimary)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Step 7: Complete

private struct CompleteStep: View {
    let isBrowseMode: Bool
    var isNewUser: Bool = false
    let onLaunch: () -> Void
    @State private var showContent = false
    @State private var ringScale: CGFloat = 0
    @State private var ringOpacity: Double = 1
    @State private var ring2Scale: CGFloat = 0
    @State private var ring2Opacity: Double = 1
    @State private var ring3Scale: CGFloat = 0
    @State private var ring3Opacity: Double = 1
    @State private var buttonPulse: Bool = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 40)

            // Celebration animation
            ZStack {
                // Expanding rings
                Circle()
                    .stroke(WizardColors.accentPrimary, lineWidth: 2)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(WizardColors.accentPrimary.opacity(0.6), lineWidth: 1.5)
                    .scaleEffect(ring2Scale)
                    .opacity(ring2Opacity)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(WizardColors.accentPrimary.opacity(0.3), lineWidth: 1)
                    .scaleEffect(ring3Scale)
                    .opacity(ring3Opacity)
                    .frame(width: 120, height: 120)

                // Checkmark seal
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(WizardColors.accentGradient)
                    .scaleEffect(showContent ? 1.0 : 0)
                    .animation(WizardAnimations.springBounce.delay(0.5), value: showContent)
            }

            // Title
            Text(isNewUser ? "Welcome to Nostr!" : (isBrowseMode ? String(localized: "setup.complete.title.browse") : String(localized: "setup.complete.title.full")))
                .font(.system(size: isIOSDevice ? 28 : 32, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 15)
                .animation(WizardAnimations.springEnter.delay(0.8), value: showContent)

            // Summary bullets
            VStack(alignment: .leading, spacing: 14) {
                if isNewUser {
                    completeBullet(icon: "checkmark.circle.fill", text: "Account created", color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "checkmark.circle.fill", text: "Relay is running", color: WizardColors.success, delay: 1.1)
                } else if isBrowseMode {
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.browse.connected"), color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "info.circle.fill", text: String(localized: "setup.complete.browse.upgradeHint"), color: WizardColors.accentPrimary, delay: 1.1)
                } else {
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.relayRunning"), color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.dmsEnabled"), color: WizardColors.success, delay: 1.1)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.blossomActive"), color: WizardColors.success, delay: 1.2)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.postsBroadcast"), color: WizardColors.success, delay: 1.3)
                }
            }

            if isNewUser {
                Text("We'll start you on the Popular feed so you can discover interesting people to follow. You can switch to the Following feed anytime.")
                    .font(.system(size: 14))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .opacity(showContent ? 1 : 0)
                    .animation(WizardAnimations.fadeIn.delay(1.3), value: showContent)
            }

            Spacer()

            #if os(macOS)
            Text(String(localized: "setup.complete.menuBarHint"))
                .font(.system(size: 14))
                .foregroundColor(WizardColors.accentPrimary.opacity(0.8))
                .opacity(showContent ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(1.5), value: showContent)
            #endif

            // Launch button with pulse
            WizardPrimaryButton(title: isNewUser ? "Start Exploring" : String(localized: "setup.complete.launch"), action: onLaunch)
                .shadow(color: buttonPulse ? WizardColors.accentGlow : .clear, radius: buttonPulse ? 16 : 8)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(1.6), value: showContent)

            Spacer().frame(height: 16)
        }
        .onAppear {
            showContent = true

            // Ring 1
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                ringScale = 2.0
                ringOpacity = 0
            }
            // Ring 2
            withAnimation(.easeOut(duration: 0.8).delay(0.35)) {
                ring2Scale = 2.0
                ring2Opacity = 0
            }
            // Ring 3
            withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
                ring3Scale = 2.0
                ring3Opacity = 0
            }

            // Button pulse loop
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let loop = Motion.ambientPulse else { return }
                withAnimation(loop) { buttonPulse = true }
            }

            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                FloatingArrowController.shared.show()
            }
            #endif
        }
    }

    private func completeBullet(icon: String, text: String, color: Color, delay: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 18))
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(WizardColors.textPrimary)
        }
        .opacity(showContent ? 1 : 0)
        .offset(x: showContent ? 0 : -20)
        .animation(WizardAnimations.springEnter.delay(delay), value: showContent)
    }
}

// MARK: - Shared Tab Pill

private func tabPill(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isActive ? WizardColors.textPrimary : WizardColors.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isActive ? WizardColors.accentPrimary : Color.clear)
            .cornerRadius(8)
    }
    .buttonStyle(.plain)
}

// MARK: - Legacy Components (kept for compatibility)

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.havenPurple)
                .frame(width: 40)
                .scaleEffect(isHovered ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(description)
                    .font(.caption)
                    .foregroundColor(isHovered ? .primary : .secondary)
            }

            Spacer()
        }
        .padding()
        .background(isHovered ? Color.havenPurplePale : Color.platformControlBackground)
        .cornerRadius(12)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct SuccessBullet: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.havenPurple)
            Text(text)
                .font(.subheadline)
        }
    }
}

struct DatabaseOption: View {
    @Binding var selected: String
    let value: String
    let title: String
    let description: String
    @State private var isHovered = false

    var body: some View {
        Button(action: { selected = value }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                    Text(description)
                        .font(.caption)
                        .foregroundColor(selected == value ? .primary : .secondary)
                }
                Spacer()
                Image(systemName: selected == value ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected == value ? .havenPurple : (isHovered ? .primary : .secondary))
                    .scaleEffect(selected == value ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
            }
            .padding()
            .background(selected == value ? Color.havenPurplePale.opacity(0.5) : (isHovered ? Color.platformControlBackground.opacity(0.8) : Color.platformControlBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected == value ? Color.havenPurple : (isHovered ? Color.gray.opacity(0.5) : Color.clear), lineWidth: 2)
            )
            .scaleEffect(isHovered && selected != value ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
