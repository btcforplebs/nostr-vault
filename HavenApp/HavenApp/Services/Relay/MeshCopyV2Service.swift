import Foundation
import Combine
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

    private static let recordKey = "meshCopyV2.record"
    private var record: MeshCopyV2.Record {
        didSet { if record != oldValue { save() } }
    }
    /// The peer the running copy (or catch-up) is with.
    private var current: String?
    private var watchers: Set<AnyCancellable> = []

    private static var now: Int { Int(Date().timeIntervalSince1970) }

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
    }

    // MARK: Start

    /// Copies this vault from the linked device `peer` (its mesh npub).
    /// Called on any link where this device is B. A second call for the
    /// same peer while one is on does nothing.
    @discardableResult
    func start(peer: String, name: String) async -> MeshCopyV2.StartResult {
        if current == peer || (starting && record.pending?.peer == peer) { return .busy }
        record.pending = .init(peer: peer, name: name, freshStart: true)
        peerName = name
        progress = nil
        return await run(peer: peer, fresh: true)
    }

    func cancel() {
        _ = CancelCopyC()
    }

    /// Remove device: B stops copying from it and never catches up with it
    /// again. A running copy with it is stopped (Tron's review of #1790).
    func forget(peer: String) {
        if current == peer { cancel() }
        record.forget(peer)
    }

    /// The pending copy resumes; copied devices get a catch-up when due.
    private func reconnect() {
        guard !starting, current == nil, RelayProcessManager.shared.isRunning else { return }
        if let p = record.pending {
            peerName = p.name
            Task { await run(peer: p.peer, fresh: p.freshStart) }
            return
        }
        guard let peer = record.syncDue(now: Self.now).first else { return }
        Task { await sync(peer: peer) }
    }

    private func sync(peer: String) async {
        guard !starting, current == nil, let base = await Self.base(peer) else { return }
        let code = MeshCopyV2.StartResult(code: peer.withCString { p in base.withCString { b in CopySyncC(mutating(p), mutating(b)) } })
        if code == .started {
            current = peer
            record.copied[peer] = Self.now
        }
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
        while Self.now - startedAt < MeshCopyV2.relayWaitWindow {
            if let base = await Self.base(peer) {
                // Signed right before the call: A wants it within 60 s.
                let auth = fresh ? await Self.signedStart(base: base) : ""
                if fresh, auth == nil { return .failed(-1) }
                let code = peer.withCString { p in
                    base.withCString { b in (auth ?? "").withCString { a in StartCopyFromC(mutating(p), mutating(b), mutating(a)) } }
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
        } else {
            RelayProcessManager.shared.addLog("Mesh copy: not started (\(result))", level: "ERROR")
        }
        return result
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

    /// This device's own mesh npub, the one its engine dials with.
    private static func ownMeshNpub() -> String? {
        #if os(iOS)
        return FipsMeshService.meshNpubFromKey()
        #else
        return MacFipsMeshService.meshNpubFromKey()
        #endif
    }

    /// Base64 of the owner's kind 27235 for POST <base>/copy/v2/start.
    private static func signedStart(base: String) async -> String? {
        guard let url = URL(string: base), let device = ownMeshNpub(),
              let tags = MeshCopyV2.startAuthTags(base: url, device: device),
              let event = await NostrService.shared.signEventAsync(kind: 27235, content: "", tags: tags, forceOwner: true),
              let json = try? JSONEncoder().encode(event) else { return nil }
        return json.base64EncodedString()
    }

    // MARK: Progress (COPY lines from the relay log)

    func handle(_ lines: [MeshCopyV2.Progress]) {
        for line in lines {
            if current != nil || record.pending != nil { progress = line }
            guard line.isFinished else { continue }
            if let peer = current ?? record.pending?.peer {
                record.finished(line, peer: peer, now: Self.now)
            }
            current = nil
            // The engine leaves the copied settings (first copy and every
            // catch-up winner) in copy-settings.json: apply them now.
            CopySettingsSync.shared.applyFromFile()
        }
    }
}

/// The C entry points take `char*`; Go never writes to them.
private func mutating(_ p: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    UnsafeMutablePointer(mutating: p)
}
