import Foundation
import Combine
import Network
#if os(iOS)
import UIKit
#endif

/// B's side of the mesh vault copy v2 (docs/MESH_COPY_V2_CONTRACT.md). The
/// engine does the transfer, the restore and the relays; this signs the one
/// start, dials the other device, and reads the `COPY` lines. It also resumes
/// a cut copy and runs the catch-up when the relay starts or the app comes
/// back, for devices copied from before. Android's twin is `MeshCopyV2.kt`.
@MainActor
final class MeshCopyV2Service: ObservableObject {
    static let shared = MeshCopyV2Service()

    /// The latest `COPY` line of the copy this app started (nil before one).
    @Published private(set) var progress: MeshCopyV2.Progress?
    /// The other device's name for the screen, while a copy is on.
    @Published private(set) var peerName = ""
    /// The start is being made (dialling, signing, waiting for the relay).
    @Published private(set) var starting = false
    /// The other device can't be reached: `.after` while B keeps trying,
    /// `.gaveUp` once it has tried for a few minutes (then `tryAgain`).
    @Published private(set) var unreachable: MeshCopyV2.Retry = .none

    private static let recordKey = "meshCopyV2.record"
    private var record: MeshCopyV2.Record {
        didSet { if record != oldValue { save() } }
    }
    /// The peer the running copy (or catch-up) is with.
    private var current: String?
    private var watchers: Set<AnyCancellable> = []
    /// The next try at an unreachable copy, while one is waiting.
    private var retryTask: Task<Void, Never>?

    private static var now: Int { Int(Date().timeIntervalSince1970) }

    /// Whether this device is on Wi-Fi (or a wire) now, for Wi-Fi only.
    private let path = NWPathMonitor()
    private var onWiFi = false

    /// A copy or catch-up is starting or running. A relay restart would cut
    /// it, so settings restarts wait for this to clear
    /// (`MeshCopyV2.settingsRestartWait`).
    var isCopyActive: Bool { starting || current != nil }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.recordKey),
           let r = try? JSONDecoder().decode(MeshCopyV2.Record.self, from: data) {
            record = r
        } else {
            record = MeshCopyV2.Record()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: Self.recordKey) }
    }

    /// Resume and catch up when the relay comes up and when the app comes back.
    func startWatching() {
        guard watchers.isEmpty else { return }
        path.pathUpdateHandler = { [weak self] p in
            let wifi = p.status == .satisfied && (p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in self?.onWiFi = wifi }
        }
        path.start(queue: DispatchQueue(label: "com.haven.mesh-copy.path"))
        RelayProcessManager.shared.$isRunning
            .removeDuplicates()
            .sink { [weak self] running in
                // A stopped relay ends its copy run (the engine keeps the
                // state); the next start resumes it.
                if running { self?.reconnect() } else { self?.current = nil }
            }
            .store(in: &watchers)
        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reconnect() }
            .store(in: &watchers)
        #endif
        CopySettingsSync.shared.startWatching()
        CopyAccountsSync.shared.startWatching()
    }

    // MARK: Start

    /// Copies this vault from the linked device `peer` (its mesh npub).
    /// Called on any link where this device is B. A second call for the
    /// same peer while one is on does nothing.
    @discardableResult
    func start(peer: String, name: String) async -> MeshCopyV2.StartResult {
        if current == peer || (starting && record.pending?.peer == peer) {
            Self.log(.alreadyRunning, peer: peer)
            return .busy
        }
        record.pending = .init(peer: peer, name: name, freshStart: true)
        record.retryNow()
        stopRetrying()
        peerName = name
        progress = nil
        return await run(peer: peer, fresh: true)
    }

    /// The failed state's Try again: a fresh few minutes of tries.
    func tryAgain() {
        guard let p = record.pending, !starting, current == nil else { return }
        record.retryNow()
        stopRetrying()
        peerName = p.name
        Task { await run(peer: p.peer, fresh: p.freshStart) }
    }

    func cancel() {
        stopRetrying()
        _ = CancelCopyC()
    }

    private func stopRetrying() {
        retryTask?.cancel()
        retryTask = nil
        unreachable = .none
    }

    /// The pending copy with `peer` missed its device: try again shortly,
    /// or, after `unreachableRetryFor`, show it failed.
    private func missed(peer: String) {
        record.missed(peer: peer, now: Self.now)
        let next = record.retry(now: Self.now)
        retryTask?.cancel()
        retryTask = nil
        unreachable = next
        guard case .after(let seconds) = next else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard let p = self.record.pending, p.peer == peer, !self.starting, self.current == nil else { return }
            await self.run(peer: p.peer, fresh: p.freshStart)
        }
    }

    /// Remove device, both sides (any device can be A or B; Tron's review of
    /// #1788/#1790). As A: the engine drops that device's copy tokens and the
    /// copies they could read, on disk too. As B: a running copy with it is
    /// stopped, and it is never resumed or caught up with again.
    func forget(peer: String) {
        let revoked = peer.withCString { RevokeCopyTokensC(mutating($0)) }
        if revoked == 0 { RelayProcessManager.shared.addLog("Mesh copy: a removed device's copy access was revoked") }
        if current == peer { cancel() }
        if record.pending?.peer == peer { stopRetrying() }
        record.forget(peer)
    }

    /// The pending copy resumes; copied devices get a catch-up when due.
    private func reconnect() {
        guard !starting, current == nil, RelayProcessManager.shared.isRunning else { return }
        if let p = record.pending {
            // The relay came up or the app came back: a fresh window of tries.
            record.retryNow()
            stopRetrying()
            peerName = p.name
            Task { await run(peer: p.peer, fresh: p.freshStart) }
            return
        }
        guard let peer = record.syncDue(now: Self.now).first else { return }
        Task { await sync(peer: peer) }
    }

    private func sync(peer: String) async {
        guard !starting, current == nil else {
            Self.log(.busyWithAnother, peer: peer)
            return
        }
        guard let base = await Self.base(peer) else {
            Self.log(.noMeshLink(seconds: 0), peer: peer)
            return
        }
        // A light phone (Full copy off), or a full one off Wi-Fi while Wi-Fi
        // only is on, catches up on notes only (multi-Mac rules §3, rule 7).
        let filesToo = catchUpMovesFiles
        let code = MeshCopyV2.StartResult(code: peer.withCString { p in base.withCString { b in
            filesToo ? CopySyncC(mutating(p), mutating(b)) : CopySyncNotesOnlyC(mutating(p), mutating(b))
        } })
        if code == .started {
            current = peer
            record.copied[peer] = Self.now
        }
    }

    /// Whether this device's catch-up moves files as well as notes.
    private var catchUpMovesFiles: Bool {
        #if os(macOS)
        return true
        #else
        let config = ConfigService.shared.config
        let full = YourDevicesLogic.keepsFullCopy(isDesktop: false, mobileVault: FipsMeshService.shared.kioskActive,
                                                  stored: config.keepFullCopy)
        return YourDevicesLogic.catchUpMovesFiles(fullCopy: full, isDesktop: false,
                                                  wifiOnly: config.fullCopyWifiOnly, onWiFi: onWiFi)
        #endif
    }

    /// Own devices' web domains learned over the mesh (CopyPeerDomainsC), by
    /// mesh npub, paired devices only. Never published (multi-Mac rules §3.3).
    static func peerDomains() -> [String: String] {
        guard let raw = CopyPeerDomainsC() else { return [:] }
        defer { free(raw) }
        guard let data = String(cString: raw).data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// Dials, signs (a fresh start only) and calls the engine, retrying
    /// while the relay is still coming up.
    private func run(peer: String, fresh: Bool) async -> MeshCopyV2.StartResult {
        starting = true
        defer { starting = false }
        if !RelayProcessManager.shared.isRunning, RelayProcessManager.shared.state != .booting {
            RelayProcessManager.shared.startRelay(config: ConfigService.shared.config)
        }
        let startedAt = Self.now
        var result = MeshCopyV2.StartResult.relayNotRunning
        // Whether the mesh ever gave a base in the wait (logged if not).
        var dialled = false
        while Self.now - startedAt < MeshCopyV2.relayWaitWindow {
            if let base = await Self.base(peer) {
                dialled = true
                // Signed right before the call: A wants it within 60 s.
                let signed = fresh ? Self.signedStart(base: base, peer: peer) : .signed("")
                guard case .signed(let auth) = signed else {
                    if case .notSigned(let why) = signed { Self.log(.notSigned(why), peer: peer) }
                    return .failed(-1)
                }
                let code = peer.withCString { p in
                    base.withCString { b in auth.withCString { a in StartCopyFromC(mutating(p), mutating(b), mutating(a)) } }
                }
                result = MeshCopyV2.StartResult(code: code)
                if result != .relayNotRunning { break }
            }
            try? await Task.sleep(nanoseconds: UInt64(MeshCopyV2.retryEvery) * 1_000_000_000)
        }
        if result.isRunning {
            current = peer
            // The engine holds the token now: a cut copy resumes without a new proof.
            if record.pending?.peer == peer { record.pending?.freshStart = false }
        } else if !dialled {
            Self.log(.noMeshLink(seconds: Self.now - startedAt), peer: peer)
            // No COPY line comes for a try that never reached the engine.
            if unreachable != .none { missed(peer: peer) }
        } else {
            RelayProcessManager.shared.addLog("Mesh copy: not started (\(result))", level: "ERROR")
        }
        return result
    }

    /// One line in the in-app log and the system log (fips-mesh).
    private static func log(_ why: MeshCopyV2.NotStarted, peer: String) {
        let line = why.line(peer: peer)
        RelayProcessManager.shared.addLog(line, level: why == .alreadyRunning || why == .busyWithAnother ? "INFO" : "ERROR")
        MeshDiagnostics.log(line)
    }

    /// The loopback base this device's mesh gives the peer's own-device
    /// port. Never log it: the path holds the ingress token.
    private static func base(_ peer: String) async -> String? {
        #if os(iOS)
        return await FipsMeshService.shared.ingressURL(meshNpub: peer)?.absoluteString
        #else
        return await MacFipsMeshService.shared.ingressURL(meshNpub: peer)?.absoluteString
        #endif
    }

    private enum SignedStart { case signed(String), notSigned(String) }

    /// Base64 of the kind 27235 for POST <base>/copy/v2/start, signed by
    /// this device's own mesh key with `p` = A's mesh npub (`peer`), or why
    /// it couldn't be made. The owner's key is never used on the mesh
    /// (docs/MESH_COPY_V2_CONTRACT.md §2); A must have this device in its
    /// paired set.
    private static func signedStart(base: String, peer: String) -> SignedStart {
        guard let url = URL(string: base) else { return .notSigned("bad base") }
        guard let tags = MeshKeyAuth.copyStartTags(base: url, receiver: peer) else { return .notSigned("no start tags") }
        guard let auth = MeshKeySigner.authorization(kind: 27235, content: "", tags: tags) else {
            return .notSigned("no mesh key on this device")
        }
        return .signed(auth)
    }

    // MARK: Progress (COPY lines from the relay log)

    func handle(_ lines: [MeshCopyV2.Progress]) {
        for line in lines {
            let following = current != nil || record.pending != nil
            let peer = current ?? record.pending?.peer
            if line.isFinished {
                if let peer { record.finished(line, peer: peer, now: Self.now) }
                current = nil
            }
            // Set before `progress`, which the copy screen follows.
            followReach(line, peer: peer)
            if following { progress = line }
            guard line.isFinished else { continue }
            // The engine leaves the copied settings (first copy and every
            // catch-up winner) in copy-settings.json: apply them now.
            CopySettingsSync.shared.applyFromFile()
            // And the accounts it brought over (§3.4): asked, never added
            // on their own.
            CopyAccountsSync.shared.refreshOffer()
        }
    }

    /// Can't reach the device: keep trying every ~15 s for a few minutes,
    /// then show it failed. A copy moving again, or ending any other way,
    /// stops the tries.
    private func followReach(_ line: MeshCopyV2.Progress, peer: String?) {
        if line.isFinished, line.error == "unreachable", let peer, record.pending?.peer == peer {
            missed(peer: peer)
        } else if unreachable != .none {
            if !line.isFinished { record.retryNow() }
            stopRetrying()
        }
    }
}

/// The C entry points take `char*`; Go never writes to them.
private func mutating(_ p: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    UnsafeMutablePointer(mutating: p)
}
