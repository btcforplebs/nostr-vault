// Two-scan pairing sessions, as iOS MeshPairingSession.swift and Android MeshPairingSession.kt
// (docs/MESH_PAIRING_CONTRACT.md §4). Pure: the caller has already checked each kind-21195 event's signature and
// decrypted it with the mesh key. Outcomes are strings: "camera", "ignoreDuplicate", "abort", "expired",
// "ignore:<why>", "refuse:<why>", "confirm", "reject:<why>" (A); "linked", "waitWords", "waitAck", … (B).
import { npubEncode } from "nostr-tools/nip19"
import { ACK_WINDOW, CODE_LIFETIME, HELLO_SKEW, SCAN_WINDOW, ackDigest, ackJson, ownerCheck, parse, parseAck, parseHello } from "./mesh-pairing.js"

const sameHello = (a, b) => !!a && !!b && a.s === b.s && a.n === b.n && a.r === b.r && a.o === b.o && a.t === b.t

/** A's side (it shows its code first). After "confirm", `device` is `{ npub, name, role }` to confirm and store. */
export class PairingSession {
  constructor({ secret, createdAt, ownMeshHex, active = null, accounts = [] }) {
    Object.assign(this, { secret, createdAt, ownMeshHex, active, accounts })
    this.state = "waiting"
    this.senderHex = null
    this.hello = null
    this.helloAt = 0
    this.device = null
    this.bSecret = null // s_B from B's scanned code; null after Accept
  }

  /** The ack content to send B once confirmed: it proves the scan (s_B), or says this side used Accept (`w`). */
  async ack() {
    if (this.state !== "done") return null
    if (this.bSecret != null) return ackJson(await ackDigest(this.secret, this.ownMeshHex, this.senderHex, this.bSecret))
    return ackJson(await ackDigest(this.secret, this.ownMeshHex, this.senderHex), true)
  }

  receiveHello(sender, content, now) {
    if (this.state === "done" || this.state === "expired") return "expired"
    if (this.state === "aborted") return "abort"
    const h = parseHello(content)
    if (!h) return "ignore:notHello"
    if (sender === this.ownMeshHex) return "ignore:ownAddress"
    if (h.s !== this.secret) return "ignore:wrongSecret"
    if (Math.abs(now - h.t) > HELLO_SKEW) return "ignore:stale"
    const oc = ownerCheck(h.o, this.active, this.accounts)
    if (oc !== "ok") return "refuse:" + oc.split(":")[0]
    if (this.state === "waiting") {
      if (now - this.createdAt > CODE_LIFETIME) {
        this.state = "expired"
        return "expired"
      }
      Object.assign(this, { state: "camera", senderHex: sender, hello: h, helloAt: now })
      return "camera"
    }
    if (sender === this.senderHex && sameHello(h, this.hello)) return "ignoreDuplicate"
    this.state = "aborted"
    return "abort"
  }

  /** B's code, scanned by A's camera. An unreadable code is "refuse:<refusal>". */
  acceptSecondQR(uri, now) {
    const stop = this.#guard(now)
    if (stop) return stop
    const r = parse(uri, npubEncode(this.ownMeshHex))
    if (r.refusal) return "refuse:" + r.refusal
    const p = r.ok
    if (p.secret != null) return "reject:notTheirCode"
    if (p.echo !== this.secret) return "reject:echoMismatch"
    if (p.meshHex !== this.senderHex || p.role !== this.hello.r) return "reject:notTheDevice"
    this.bSecret = p.bSecret
    return this.#finish()
  }

  /** Accept with the check words, on a device that can't scan (§4). */
  acceptWithoutScan(now) {
    return this.#guard(now) ?? this.#finish()
  }

  #guard(now) {
    if (this.state === "aborted") return "abort"
    if (this.state === "done" || this.state === "expired") return "expired"
    if (this.state === "waiting") return "reject:notReady"
    if (now - this.helloAt > SCAN_WINDOW) {
      this.state = "expired"
      return "expired"
    }
    return null
  }

  #finish() {
    this.state = "done"
    this.device = { npub: npubEncode(this.senderHex), name: this.hello.n, role: this.hello.r }
    return "confirm"
  }
}

/** B's side (it scanned A): waits for A's ack, and on the Accept path for this side's own tap too (Tron 2). */
export class PairingJoiner {
  /** Null unless `qrA` (a parse() payload) is A's code. `ownSecret` is s_B, the secret in this device's code. */
  static async start(qrA, ownMeshHex, ownSecret, scannedAt) {
    if (qrA?.secret == null) return null
    const expectScan = await ackDigest(qrA.secret, qrA.meshHex, ownMeshHex, ownSecret)
    if (!expectScan) return null
    return new PairingJoiner(qrA, ownMeshHex, scannedAt, expectScan, await ackDigest(qrA.secret, qrA.meshHex, ownMeshHex))
  }

  constructor(a, ownMeshHex, scannedAt, expectScan, expectWords) {
    Object.assign(this, { a, ownMeshHex, scannedAt, expectScan, expectWords })
    this.state = "waiting"
    this.wordsConfirmed = false
  }

  /** The device to store once linked. */
  get device() {
    return { npub: this.a.mesh, name: this.a.name, role: this.a.role }
  }

  receiveAck(sender, content, now) {
    if (this.state === "linked") return "ignoreDuplicate"
    if (this.state === "expired") return "expired"
    const ack = parseAck(content)
    if (!ack) return "ignore:notAck"
    if (sender !== this.a.meshHex) return "ignore:wrongSender"
    // Without `w` only the scan digest (with s_B) counts: A can make the other one without reading B's code.
    if (ack.d !== (ack.w ? this.expectWords : this.expectScan)) return "ignore:badDigest"
    if (now - this.scannedAt > ACK_WINDOW) {
      this.state = "expired"
      return "expired"
    }
    if (ack.w && !this.wordsConfirmed) {
      this.state = "waitWords"
      return "waitWords"
    }
    this.state = "linked"
    return "linked"
  }

  confirmWords(now) {
    if (this.state === "linked") return "ignoreDuplicate"
    if (this.state === "expired") return "expired"
    if (now - this.scannedAt > ACK_WINDOW) {
      this.state = "expired"
      return "expired"
    }
    if (this.state === "waitWords") {
      this.state = "linked"
      return "linked"
    }
    this.wordsConfirmed = true
    return "waitAck"
  }
}
