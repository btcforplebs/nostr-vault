import Foundation

/// A's side of a pairing (it shows its code first): takes hellos and B's
/// code, and says what to do. Pure: the caller has already checked the
/// hello event's signature and decrypted it with the mesh key.
/// docs/MESH_PAIRING_CONTRACT.md §4.
struct MeshPairingSession {
    enum Outcome: Equatable {
        /// The hello is good: open the camera on B.
        case camera(MeshPairing.Hello)
        case ignoreDuplicate
        /// Two hellos for one code (Tron 3): stop, nothing is stored.
        case abort
        case expired
        /// Not for this session; keep waiting quietly.
        case ignore(Ignore)
        case refuse(Refuse)
        /// B is confirmed: show the role confirm, then store it.
        case confirm(MeshDevice)
        case reject(Reject)
        /// B's code didn't read; say why with `MeshPairing.text`.
        case unreadable(MeshPairing.Refusal)
    }

    enum Ignore: String { case notHello, ownAddress, wrongSecret, stale }
    enum Refuse: String { case otherOwner, switchTo }
    enum Reject: String { case notReady, notTheirCode, echoMismatch, notTheDevice }

    enum State: Equatable { case waiting, camera, done, expired, aborted }

    let secret: String
    let createdAt: Int
    let ownMeshHex: String
    let active: String?
    let accounts: [String]
    /// The Apple apps' rule: a hello from a device that shares any account
    /// with this one is taken (`MeshPairing.sharesAccount`). Off, the shared
    /// contract's `ownerCheck` (active only, else switchTo) that Android and
    /// the fixtures still use.
    let matchAnyAccount: Bool
    private(set) var state: State = .waiting
    private(set) var senderHex: String?
    private(set) var hello: MeshPairing.Hello?
    private var helloAt = 0
    /// s_B from B's scanned code; nil after Accept.
    private var bSecret: String?

    init(secret: String, createdAt: Int, ownMeshHex: String, active: String?, accounts: [String],
         matchAnyAccount: Bool = false) {
        self.secret = secret
        self.createdAt = createdAt
        self.ownMeshHex = ownMeshHex
        self.active = active
        self.accounts = accounts
        self.matchAnyAccount = matchAnyAccount
    }

    mutating func receiveHello(senderHex sender: String, content: String, now: Int) -> Outcome {
        switch state {
        case .done, .expired: return .expired
        case .aborted: return .abort
        case .waiting, .camera: break
        }
        guard let h = MeshPairing.parseHello(content) else { return .ignore(.notHello) }
        guard sender != ownMeshHex else { return .ignore(.ownAddress) }
        guard h.secret == secret else { return .ignore(.wrongSecret) }
        guard abs(now - h.time) <= MeshPairing.helloSkew else { return .ignore(.stale) }
        if matchAnyAccount {
            // `accounts` is what this device pairs on (signing accounts only);
            // the active account counts only if it is one of them.
            guard MeshPairing.sharesAccount(owner: h.owner, theirs: h.accounts, mine: accounts) else {
                return .refuse(.otherOwner)
            }
        } else {
            switch MeshPairing.ownerCheck(owner: h.owner, active: active, accounts: accounts) {
            case .ok: break
            case .switchTo: return .refuse(.switchTo)
            case .otherOwner: return .refuse(.otherOwner)
            }
        }
        if state == .waiting {
            guard now - createdAt <= MeshPairing.codeLifetime else {
                state = .expired
                return .expired
            }
            state = .camera
            senderHex = sender
            hello = h
            helloAt = now
            return .camera(h)
        }
        if sender == senderHex, h == hello { return .ignoreDuplicate }
        state = .aborted
        return .abort
    }

    /// B's code, scanned by A's camera.
    mutating func acceptSecondQR(_ uri: String, now: Int) -> Outcome {
        if let stop = guardScan(now: now) { return stop }
        let payload: MeshPairing.Payload
        switch MeshPairing.parse(uri, ownMesh: MeshPairing.npub(hex: ownMeshHex)) {
        case .failure(let e): return .unreadable(e.refusal)
        case .success(let p): payload = p
        }
        guard case .echo(let echo, let b) = payload.code else { return .reject(.notTheirCode) }
        guard echo == secret else { return .reject(.echoMismatch) }
        guard payload.meshHex == senderHex, payload.role == hello?.role else { return .reject(.notTheDevice) }
        bSecret = b
        return finish()
    }

    /// Accept with the check words, on a device that can't scan (§4).
    mutating func acceptWithoutScan(now: Int) -> Outcome {
        if let stop = guardScan(now: now) { return stop }
        return finish()
    }

    /// The ack content to send B once confirmed: it proves the scan (s_B), or
    /// says this side used Accept (`w`). Nil before `confirm`.
    var ack: String? {
        guard state == .done, let senderHex else { return nil }
        if let bSecret {
            return MeshPairing.ackDigest(secret: secret, bSecret: bSecret, aHex: ownMeshHex, bHex: senderHex)
                .map { MeshPairing.ackJSON(digest: $0, words: false) }
        }
        return MeshPairing.ackDigest(secret: secret, aHex: ownMeshHex, bHex: senderHex)
            .map { MeshPairing.ackJSON(digest: $0, words: true) }
    }

    private mutating func guardScan(now: Int) -> Outcome? {
        switch state {
        case .aborted: return .abort
        case .done, .expired: return .expired
        case .waiting: return .reject(.notReady)
        case .camera:
            guard now - helloAt <= MeshPairing.scanWindow else {
                state = .expired
                return .expired
            }
            return nil
        }
    }

    private mutating func finish() -> Outcome {
        state = .done
        guard let senderHex, let hello else { return .reject(.notReady) }
        return .confirm(MeshDevice(npub: MeshPairing.npub(hex: senderHex), name: hello.name, role: hello.role))
    }
}

/// B's side (it scanned A): waits for A's ack, and on the Accept path for
/// this side's own "They match" tap too (Tron 2).
struct MeshPairingJoiner {
    enum Outcome: Equatable {
        case linked
        case waitWords
        case waitAck
        case ignoreDuplicate
        case expired
        case ignore(Ignore)
    }

    enum Ignore: String { case notAck, wrongSender, badDigest }

    enum State: Equatable { case waiting, waitWords, linked, expired }

    let a: MeshPairing.Payload
    let ownMeshHex: String
    let scannedAt: Int
    private let expectScan: String?
    private let expectWords: String?
    private(set) var state: State = .waiting
    private var wordsConfirmed = false

    /// Nil unless `qrA` is A's code (a secret, not an echo). `ownSecret` is
    /// s_B, the fresh secret in the code this device shows.
    init?(qrA: MeshPairing.Payload, ownMeshHex: String, ownSecret: String, scannedAt: Int) {
        guard case .secret(let s) = qrA.code, MeshPairing.secretBytes(ownSecret) != nil else { return nil }
        a = qrA
        self.ownMeshHex = ownMeshHex
        self.scannedAt = scannedAt
        expectScan = MeshPairing.ackDigest(secret: s, bSecret: ownSecret, aHex: qrA.meshHex, bHex: ownMeshHex)
        expectWords = MeshPairing.ackDigest(secret: s, aHex: qrA.meshHex, bHex: ownMeshHex)
    }

    /// The device to store once linked.
    var device: MeshDevice { MeshDevice(npub: a.mesh, name: a.name, role: a.role) }

    mutating func receiveAck(senderHex: String, content: String, now: Int) -> Outcome {
        switch state {
        case .linked: return .ignoreDuplicate
        case .expired: return .expired
        case .waiting, .waitWords: break
        }
        guard let ack = MeshPairing.parseAck(content) else { return .ignore(.notAck) }
        guard senderHex == a.meshHex else { return .ignore(.wrongSender) }
        // Without `w` only the scan digest (with s_B) counts: A can make the
        // other one without ever reading B's code (Tron, PR 1700).
        guard ack.digest == (ack.words ? expectWords : expectScan) else { return .ignore(.badDigest) }
        guard now - scannedAt <= MeshPairing.ackWindow else {
            state = .expired
            return .expired
        }
        if ack.words && !wordsConfirmed {
            state = .waitWords
            return .waitWords
        }
        state = .linked
        return .linked
    }

    mutating func confirmWords(now: Int) -> Outcome {
        switch state {
        case .linked: return .ignoreDuplicate
        case .expired: return .expired
        case .waiting, .waitWords: break
        }
        guard now - scannedAt <= MeshPairing.ackWindow else {
            state = .expired
            return .expired
        }
        switch state {
        case .linked, .expired: return .expired
        case .waitWords:
            state = .linked
            return .linked
        case .waiting:
            wordsConfirmed = true
            return .waitAck
        }
    }
}
