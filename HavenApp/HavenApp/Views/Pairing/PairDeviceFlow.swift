import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Linking two of your own devices with two scans (docs/MESH_PAIRING_CONTRACT.md).
/// This device plays A (shows its code first, then scans the other's) or B
/// (scans first, then shows its own). The rules live in MeshPairingSession and
/// MeshPairingJoiner; this drives them with the relays, the camera and the
/// person's taps, and stores the device only at the last step.
@MainActor
final class PairDeviceFlow: ObservableObject {
    enum Step: Equatable {
        case start
        /// A: showing its code, waiting for the other device's hello.
        case showing(qr: String)
        /// A: the hello came; scan the other device's code (or Accept on the Mac).
        case scanning(name: String, words: [String], short: String)
        /// B: showing its own code, waiting for A's ack.
        case joined(qr: String, name: String, words: [String], short: String, needsWordsTap: Bool)
        /// Either side: the role in plain words, before anything is stored.
        case confirmRole(text: String, short: String)
        case linked(name: String, already: Bool)
        /// Stopped: plain words and a way back.
        case failed(String)
    }

    @Published private(set) var step: Step = .start
    /// A refusal that doesn't stop A's session (another owner's hello).
    @Published private(set) var notice: String?
    /// Bumped to give the camera a fresh start after a rejected code.
    @Published private(set) var scanToken = 0
    @Published private(set) var secondsLeft: Int?

    private let config: ConfigService
    private var own: MeshPairingHello.OwnMesh?
    private var hello: MeshPairingHello?
    private var session: MeshPairingSession?
    private var joiner: MeshPairingJoiner?
    private var pending: MeshDevice?
    /// B: its own fresh s_B, in the code it shows.
    private var ownSecret: String?
    private var ticker: Timer?
    /// A: when the hello came, for the scan window's countdown.
    private var helloAt: Int?

    init(config: ConfigService) {
        self.config = config
    }

    /// Accept with the check words is offered only on a device with no
    /// usable camera for a phone screen: the Mac (contract §5, T3).
    static var offersAccept: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: This device

    private var activeNpub: String {
        let active = config.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return active.isEmpty ? config.config.ownerNpub : active
    }

    /// The device model's name until Logen picks defaults (Tod, 2026-11-04).
    static var ownName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }

    static var ownRole: MeshDeviceRole {
        #if os(iOS)
        .phone
        #else
        .mac
        #endif
    }

    private var existing: [MeshDevice] {
        #if os(iOS)
        FipsMeshDevices.current(config.config)
        #else
        config.config.meshDevices
        #endif
    }

    private func loadOwn() -> MeshPairingHello.OwnMesh? {
        if let own { return own }
        if MeshPairingHello.ownMesh() == nil {
            // The engine makes the key the first time it is asked for it.
            #if os(iOS)
            _ = FipsMeshService.meshNpubFromKey()
            #else
            _ = MacFipsMeshService.meshNpubFromKey()
            #endif
        }
        own = MeshPairingHello.ownMesh()
        return own
    }

    private func startRelays(_ own: MeshPairingHello.OwnMesh) {
        hello?.stop()
        let service = MeshPairingHello(own: own, relays: MeshPairingHello.finderRelays) { [weak self] incoming in
            self?.received(incoming)
        }
        hello = service
        service.start()
    }

    private static var now: Int { Int(Date().timeIntervalSince1970) }

    // MARK: A: show my code

    func showMyCode() {
        reset()
        guard let own = loadOwn() else { return fail("This device's mesh key couldn't be read. Open Mesh settings once, then try again.") }
        let secret = MeshPairing.newSecret()
        session = MeshPairingSession(secret: secret, createdAt: Self.now, ownMeshHex: own.hex,
                                     active: activeNpub, accounts: config.allAccountNpubs)
        startRelays(own)
        let qr = MeshPairing.build(mesh: own.npub, name: Self.ownName, role: Self.ownRole, owner: activeNpub, code: .secret(secret))
        step = .showing(qr: qr)
        startTicker()
    }

    /// A: the other device's code, from the camera.
    func scannedTheirCode(_ text: String) {
        guard var session else { return }
        let outcome = session.acceptSecondQR(text, now: Self.now)
        self.session = session
        handleA(outcome)
    }

    /// A on the Mac: the person checked the words on both screens.
    func acceptWithWords() {
        guard Self.offersAccept, var session else { return }
        let outcome = session.acceptWithoutScan(now: Self.now)
        self.session = session
        handleA(outcome)
    }

    private func handleA(_ outcome: MeshPairingSession.Outcome) {
        switch outcome {
        case .camera(let h):
            guard let session, let sender = session.senderHex, let own else { return }
            let words = MeshPairing.checkWords(aHex: own.hex, bHex: sender, secret: session.secret) ?? []
            notice = nil
            helloAt = Self.now
            step = .scanning(name: MeshPairing.displayName(h.name), words: words,
                             short: MeshPairing.shortAddress(MeshPairing.npub(hex: sender)))
        case .confirm(let device):
            confirm(device)
        case .abort:
            fail(MeshPairing.abortText)
        case .expired:
            fail(MeshPairing.expiredText)
        case .refuse(let r):
            notice = r == .otherOwner ? MeshPairing.otherOwnerText : "A device on another account on this device scanned this code. Switch to it first."
        case .reject(let r):
            notice = r == .notTheDevice || r == .echoMismatch
                ? "That's not the device that scanned this code. Scan the screen of the device you're linking."
                : "That's not the other device's code. Scan the code it shows now."
            scanToken += 1
        case .unreadable(let refusal):
            notice = MeshPairing.text(refusal)
            scanToken += 1
        case .ignore, .ignoreDuplicate:
            break
        }
    }

    // MARK: B: scan their code

    /// B: the first device's code, from the camera. Nil when it's taken, or
    /// the words to show over the camera.
    func scannedFirstCode(_ text: String) -> String? {
        guard let own = loadOwn() else { return "This device's mesh key couldn't be read. Open Mesh settings once, then try again." }
        let payload: MeshPairing.Payload
        switch MeshPairing.parse(text, ownMesh: own.npub) {
        case .failure(let e): return MeshPairing.text(e.refusal)
        case .success(let p): payload = p
        }
        guard case .secret = payload.code else {
            return "That's the code from the second step. Scan the code on the device that showed one first."
        }
        switch MeshPairing.ownerCheck(owner: payload.owner, active: activeNpub, accounts: config.allAccountNpubs) {
        case .ok: break
        case .switchTo(let npub): return MeshPairing.switchToText(accountName: MeshPairing.shortAddress(npub))
        case .otherOwner: return MeshPairing.otherOwnerText
        }
        if case .refuseOtherRole(let role) = MeshPairing.roleCheck(npub: payload.mesh, role: payload.role, existing: existing) {
            return MeshPairing.otherRoleText(role)
        }
        let sB = MeshPairing.newSecret()
        guard let j = MeshPairingJoiner(qrA: payload, ownMeshHex: own.hex, ownSecret: sB, scannedAt: Self.now) else {
            return MeshPairing.unreadable
        }
        reset()
        self.own = own
        ownSecret = sB
        joiner = j
        pending = j.device
        // B confirms the role before it says hello: nothing is sent or stored
        // for a device the person didn't mean to add.
        step = .confirmRole(text: MeshPairing.roleConfirmText(role: payload.role, name: payload.name),
                            short: MeshPairing.shortAddress(payload.mesh))
        // The hello must go out while A's ack can still reach this side.
        startTicker()
        return nil
    }

    private func sayHello() {
        guard let joiner, let own, let sB = ownSecret, case .secret(let sA) = joiner.a.code else { return }
        startRelays(own)
        let content = MeshPairing.helloJSON(secret: sA, name: Self.ownName, role: Self.ownRole, owner: activeNpub, time: Self.now)
        guard hello?.send(content, toHex: joiner.a.meshHex) == true else {
            return fail("This device's mesh key couldn't be read. Open Mesh settings once, then try again.")
        }
        let qr = MeshPairing.build(mesh: own.npub, name: Self.ownName, role: Self.ownRole, owner: activeNpub,
                                   code: .echo(sA, bSecret: sB))
        let words = MeshPairing.checkWords(aHex: joiner.a.meshHex, bHex: own.hex, secret: sA) ?? []
        step = .joined(qr: qr, name: MeshPairing.displayName(joiner.a.name), words: words,
                       short: MeshPairing.shortAddress(joiner.a.mesh), needsWordsTap: false)
        startTicker()
    }

    /// B: "They match", after A linked with the words (a `w` ack).
    func wordsMatch() {
        guard var joiner else { return }
        let outcome = joiner.confirmWords(now: Self.now)
        self.joiner = joiner
        handleB(outcome)
    }

    private func handleB(_ outcome: MeshPairingJoiner.Outcome) {
        switch outcome {
        case .linked:
            guard let device = pending else { return }
            store(device)
        case .waitWords:
            if case .joined(let qr, let name, let words, let short, _) = step {
                step = .joined(qr: qr, name: name, words: words, short: short, needsWordsTap: true)
            }
        case .expired:
            fail(MeshPairing.expiredText)
        case .waitAck, .ignoreDuplicate, .ignore:
            break
        }
    }

    // MARK: Both

    private func received(_ incoming: MeshPairingHello.Incoming) {
        if var session {
            let outcome = session.receiveHello(senderHex: incoming.senderHex, content: incoming.content, now: Self.now)
            self.session = session
            handleA(outcome)
        } else if var joiner {
            let outcome = joiner.receiveAck(senderHex: incoming.senderHex, content: incoming.content, now: Self.now)
            self.joiner = joiner
            handleB(outcome)
        }
    }

    /// A: B is confirmed; the role check, then the person's tap.
    private func confirm(_ device: MeshDevice) {
        switch MeshPairing.roleCheck(npub: device.npub, role: device.role, existing: existing) {
        case .refuseOtherRole(let role):
            fail(MeshPairing.otherRoleText(role))
        case .alreadyLinked:
            sendAck()
            finish(device, already: true)
        case .add:
            pending = device
            step = .confirmRole(text: MeshPairing.roleConfirmText(role: device.role, name: device.name),
                                short: MeshPairing.shortAddress(device.npub))
        }
    }

    /// The person tapped Add on the role confirm. Past the step's deadline
    /// (MeshPairingConfirmWindow) it fails rather than store or send.
    func roleConfirmed() {
        if let left = confirmSecondsLeft(now: Self.now), !MeshPairingConfirmWindow.mayConfirm(secondsLeft: left) {
            return fail(MeshPairing.expiredText)
        }
        if session != nil {
            guard let device = pending else { return }
            store(device)
            sendAck()
        } else if joiner != nil {
            sayHello()
        }
    }

    private func sendAck() {
        guard let session, let ack = session.ack, let sender = session.senderHex else { return }
        hello?.send(ack, toHex: sender)
    }

    private func store(_ device: MeshDevice) {
        #if os(iOS)
        if let error = FipsMeshDevices.add(address: device.npub, name: device.name, role: device.role, config: config) {
            return fail(error)
        }
        #else
        config.config.meshDevices = MeshDevicesLogic.adding(device, to: config.config.meshDevices)
        config.save()
        MacFipsMeshService.shared.sync()
        #endif
        finish(device, already: false)
    }

    private func finish(_ device: MeshDevice, already: Bool) {
        stopTicker()
        notice = nil
        step = .linked(name: MeshPairing.displayName(device.name), already: already)
        // A keeps resending the ack while this screen is open; B is done.
        if joiner != nil { stopRelays() }
    }

    private func fail(_ text: String) {
        stopTicker()
        stopRelays()
        session = nil
        joiner = nil
        pending = nil
        step = .failed(text)
    }

    func cancel() {
        reset()
        step = .start
    }

    private func reset() {
        stopTicker()
        stopRelays()
        session = nil
        joiner = nil
        pending = nil
        ownSecret = nil
        helloAt = nil
        notice = nil
        scanToken = 0
    }

    private func stopRelays() {
        hello?.stop()
        hello = nil
    }

    // MARK: Countdown

    private func startTicker() {
        stopTicker()
        tick()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        secondsLeft = nil
    }

    /// Seconds left on the role confirm: A counts from the hello, B from its scan.
    private func confirmSecondsLeft(now: Int) -> Int? {
        if session != nil, let helloAt {
            return MeshPairingConfirmWindow.secondsLeftForA(helloAt: helloAt, now: now)
        }
        if session == nil, let joiner {
            return MeshPairingConfirmWindow.secondsLeftForB(scannedAt: joiner.scannedAt, now: now)
        }
        return nil
    }

    /// The window that's running out, so an unanswered code says so on its
    /// own instead of waiting forever.
    private func tick() {
        let now = Self.now
        var left: Int?
        switch step {
        case .showing:
            if let session { left = MeshPairing.codeLifetime - (now - session.createdAt) }
        case .scanning:
            if let helloAt { left = MeshPairing.scanWindow - (now - helloAt) }
        case .joined:
            if let joiner { left = MeshPairing.ackWindow - (now - joiner.scannedAt) }
        case .confirmRole:
            left = confirmSecondsLeft(now: now)
        default:
            left = nil
        }
        secondsLeft = left.map { max(0, $0) }
        if let left, left <= 0 { fail(MeshPairing.expiredText) }
    }
}

/// The pairing sheet: one screen per step of `PairDeviceFlow`.
struct PairDeviceView: View {
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = PairDeviceFlowHolder()

    var body: some View {
        NavigationStack {
            ScrollView {
                content(holder.flow(configService))
                    .padding(20)
            }
            .navigationTitle("Add a device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        .onDisappear { holder.current?.cancel() }
    }

    private func close() {
        holder.current?.cancel()
        dismiss()
    }

    @ViewBuilder
    private func content(_ flow: PairDeviceFlow) -> some View {
        PairDeviceSteps(flow: flow, done: close)
    }
}

/// Keeps one flow for the sheet's life (it needs the environment's config).
@MainActor
final class PairDeviceFlowHolder: ObservableObject {
    private(set) var current: PairDeviceFlow?

    func flow(_ config: ConfigService) -> PairDeviceFlow {
        if let current { return current }
        let made = PairDeviceFlow(config: config)
        current = made
        return made
    }
}

private struct PairDeviceSteps: View {
    @ObservedObject var flow: PairDeviceFlow
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch flow.step {
            case .start:
                start
            case .showing(let qr):
                PairShowQRView(qr: qr, caption: "On your other device, open Add a device and tap Scan a code.",
                               secondsLeft: flow.secondsLeft)
                ProgressView("Waiting for it to scan…")
                    .frame(maxWidth: .infinity)
            case .scanning(let name, let words, let short):
                Text("\(name) scanned this device. Scan its screen to finish.")
                    .font(.appBody)
                PairScanView(title: "Point the camera at \(name)'s code",
                             validate: { MeshPairing.parse($0, ownMesh: nil).failureText },
                             onCancel: { flow.cancel() }) { flow.scannedTheirCode($0) }
                    .id(flow.scanToken)
                if PairDeviceFlow.offersAccept, !words.isEmpty {
                    Divider()
                    PairCheckWordsView(words: words, short: short,
                                       caption: "Can't scan? Check that \(name) shows these same words.")
                    Button("They match. Accept \(name)") { flow.acceptWithWords() }
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                        .frame(maxWidth: .infinity)
                }
            case .joined(let qr, let name, let words, let short, let needsWordsTap):
                PairShowQRView(qr: qr, caption: "Now let \(name) scan this code.", secondsLeft: flow.secondsLeft)
                if !words.isEmpty {
                    PairCheckWordsView(words: words, short: short,
                                       caption: needsWordsTap
                                           ? "\(name) accepted without scanning. Check it shows these same words."
                                           : "If \(name) asks, it shows these same words.")
                }
                if needsWordsTap {
                    Button("They match") { flow.wordsMatch() }
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView("Waiting for \(name)…")
                        .frame(maxWidth: .infinity)
                }
            case .confirmRole(let text, let short):
                Text(text).font(.appBody)
                Text(short)
                    .font(.appSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                if let secondsLeft = flow.secondsLeft {
                    Text("Tap Add within \(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))")
                        .font(.appCaption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { flow.cancel() }
                    Spacer()
                    Button("Add") { flow.roleConfirmed() }
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                }
            case .linked(let name, let already):
                PairLinkedView(name: name, already: already, done: done)
            case .failed(let text):
                Text(text).font(.appBody)
                Button("Start again") { flow.cancel() }
                    .buttonStyle(.borderedProminent)
                    .tint(.havenPurple)
            }
            if let notice = flow.notice {
                Text(notice)
                    .font(.appCaption)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var start: some View {
        Text("Link another of your devices. One shows a code, the other scans it, then they swap.")
            .font(.appBody)
        Button {
            flow.showMyCode()
        } label: {
            Label("Show my code", systemImage: "qrcode")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.havenPurple)
        ScanFirstCode(flow: flow)
    }
}

/// B's first step: scan the code the other device shows.
private struct ScanFirstCode: View {
    @ObservedObject var flow: PairDeviceFlow
    @State private var scanning = false

    var body: some View {
        if scanning {
            PairScanView(title: "Point the camera at your other device's code",
                         validate: { flow.scannedFirstCode($0) },
                         onCancel: { scanning = false }) { _ in scanning = false }
        } else {
            Button {
                scanning = true
            } label: {
                Label("Scan a code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

private extension Result where Success == MeshPairing.Payload, Failure == MeshPairing.RefusalError {
    var failureText: String? {
        if case .failure(let e) = self { return MeshPairing.text(e.refusal) }
        return nil
    }
}
