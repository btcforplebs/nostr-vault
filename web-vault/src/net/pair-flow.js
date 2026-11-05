// The two sides of two-scan pairing on the web, as state the screen (PairDevice.jsx) draws. ShowFlow is A (this browser
// shows its code first), ScanFlow is B (it scans the other device's code). The rules are the phase-0 sessions
// (mesh-pairing-session.js); this adds the wire (pair-hello.js), the clock, the role confirm and the store
// (pair-devices.js). Nothing is stored before the last step: A after scanning B (or Accept) and the role confirm,
// B after the ack and the role confirm. Leaving at any step stores nothing.
import { npubEncode } from "nostr-tools/nip19"
import { ACK_WINDOW, CODE_LIFETIME, SCAN_WINDOW, build, checkWords, helloJson, newSecret, ownerCheck, parse, refusalText, roleCheck, roleConfirmText, shortAddress } from "./mesh-pairing.js"
import { PairingJoiner, PairingSession } from "./mesh-pairing-session.js"
import { listenHellos, openHello, ownMeshHex, sealHello, sendHello } from "./pair-hello.js"
import { addPaired, pairedDevices, roleCheckList } from "./pair-devices.js"

export const ROLE = "browser"
/** Seconds between resends of the same event while the other side may not have it yet. */
export const RESEND_EVERY = 5
const ACK_SENDS = 4

export const NOT_THEIR_CODE = "That's not the code on the device that scanned this one. Scan the code it shows now."
export const SECOND_CODE = "That's a reply code. Scan the code on the device you started from."
export const NO_CAMERA_SCAN = "This browser can't use a camera. Show this browser's code instead and scan it with your other device."

const nowSec = () => Math.floor(Date.now() / 1000)
const defaultNet = { send: ev => sendHello(ev), listen: (hex, onEvent) => listenHellos(hex, onEvent) }

class Flow {
  constructor({ account, accounts = [], name, storage, liveOwners, net = defaultNet, now = nowSec, onChange = () => {} }) {
    Object.assign(this, { account, accounts, name, storage, liveOwners, net, now, onChange })
    this.view = { step: "starting" }
    this.closeListen = null
    this.pending = null // { ev, left, at }: an event to resend byte for byte
  }

  get activeNpub() { return npubEncode(this.account) }
  get accountNpubs() { return this.accounts.map(a => npubEncode(a)) }

  set(view) {
    this.view = view
    this.onChange(view)
  }

  note(text) { this.set({ ...this.view, notice: text }) }

  async sendKept(ev, times = Infinity) {
    this.pending = { ev, left: times - 1, at: this.now() }
    await this.net.send(ev)
  }

  /** Called about once a second: expiry and resends. */
  tick() {
    const t = this.now()
    const p = this.pending
    if (p && p.left > 0 && t - p.at >= RESEND_EVERY) {
      Object.assign(p, { left: p.left - 1, at: t })
      this.net.send(p.ev)
    }
    this.expire(t)
  }

  /** The role check and confirm text for `device` from the other side, before anything is stored. */
  roleStep(device) {
    const check = roleCheck(device.npub, device.role, roleCheckList(pairedDevices(this.storage), device.role))
    if (check === "add") return { step: "confirm", device, text: roleConfirmText(device.role, device.name) }
    if (check === "alreadyLinked") return { step: "already", device, text: refusalText("alreadyLinked") }
    return { step: "refused", text: refusalText("refuseOtherRole", { role: check.split(":")[1] }) }
  }

  stop() {
    this.closeListen?.()
    this.closeListen = null
    this.pending = null
  }

  end(view) {
    this.stop()
    this.set(view)
  }

  expire() {}
}

/** A: this browser shows its code. */
export class ShowFlow extends Flow {
  async start() {
    this.stop()
    this.ownHex = await ownMeshHex(this.storage)
    const secret = newSecret(), createdAt = this.now()
    this.session = new PairingSession({ secret, createdAt, ownMeshHex: this.ownHex, active: this.activeNpub, accounts: this.accountNpubs })
    this.createdAt = createdAt
    this.closeListen = this.net.listen(this.ownHex, ev => this.onEvent(ev))
    const qr = build({ m: npubEncode(this.ownHex), n: this.name, r: ROLE, o: this.activeNpub, s: secret })
    this.set({ step: "showing", qr, expiresAt: createdAt + CODE_LIFETIME })
  }

  async onEvent(ev) {
    const opened = await openHello(ev, { ownHex: this.ownHex, storage: this.storage })
    if (!opened) return
    const out = this.session.receiveHello(opened.sender, opened.content, this.now())
    if (out === "camera") {
      const h = this.session.hello
      const words = await checkWords(this.ownHex, opened.sender, this.session.secret)
      this.set({ step: "scanBack", name: h.n, role: h.r, words, address: shortAddress(npubEncode(opened.sender)), cameraOff: false, expiresAt: this.now() + SCAN_WINDOW })
    } else if (out === "abort") this.end({ step: "aborted", text: refusalText("abort") })
    else if (out === "expired" && this.view.step !== "linked" && this.view.step !== "confirm" && this.view.step !== "already") this.end({ step: "expired", text: refusalText("expired") })
    else if (out.startsWith("refuse:")) this.note(refusalText(out.slice(7)))
  }

  /** The camera can't be used here: the Accept path with the check words (contract §5). */
  noCamera() {
    if (this.view.step === "scanBack") this.set({ ...this.view, cameraOff: true })
  }

  /** B's code from the camera. */
  scanned(text) {
    if (this.view.step !== "scanBack") return
    const out = this.session.acceptSecondQR(text, this.now())
    this.after(out)
  }

  /** "They match", on a browser with no usable camera. */
  accept() {
    if (this.view.step !== "scanBack" || !this.view.cameraOff) return
    this.after(this.session.acceptWithoutScan(this.now()))
  }

  after(out) {
    if (out === "confirm") {
      const v = this.roleStep(this.session.device)
      // Already linked: still answer, so the other side finishes too. Its own role check decides there.
      if (v.step === "already") this.sendAck()
      if (v.step === "refused") this.stop()
      this.set(v)
    } else if (out === "abort") this.end({ step: "aborted", text: refusalText("abort") })
    else if (out === "expired") this.end({ step: "expired", text: refusalText("expired") })
    else if (out.startsWith("refuse:")) this.note(refusalText(out.slice(7)))
    else if (out.startsWith("reject:")) this.note(NOT_THEIR_CODE)
  }

  async sendAck() {
    const content = await this.session.ack()
    const ev = await sealHello({ toHex: this.session.senderHex, content, now: this.now(), storage: this.storage })
    this.closeListen?.()
    this.closeListen = null
    await this.sendKept(ev, ACK_SENDS)
  }

  /** The person confirmed the role: store, then tell B. */
  async confirmRole() {
    if (this.view.step !== "confirm") return
    const device = this.view.device
    addPaired(device, { storage: this.storage, liveOwners: this.liveOwners })
    this.set({ step: "linked", device })
    await this.sendAck()
  }

  expire(t) {
    const v = this.view
    if (v.step === "showing" && t - this.createdAt > CODE_LIFETIME) this.end({ step: "expired", text: refusalText("expired") })
    else if (v.step === "scanBack" && t - this.session.helloAt > SCAN_WINDOW) this.end({ step: "expired", text: refusalText("expired") })
    if (["linked", "already"].includes(this.view.step) && this.pending?.left === 0) this.pending = null
  }
}

/** B: this browser scans the other device's code. */
export class ScanFlow extends Flow {
  async start() {
    this.stop()
    this.ownHex = await ownMeshHex(this.storage)
    this.set({ step: "scanning" })
  }

  noCamera() {
    if (this.view.step === "scanning") this.set({ ...this.view, cameraOff: true, notice: NO_CAMERA_SCAN })
  }

  /** A's code from the camera. */
  async scanned(text) {
    if (this.view.step !== "scanning" || this.busy) return
    const r = parse(text, npubEncode(this.ownHex))
    if (r.refusal) return this.note(refusalText(r.refusal))
    const a = r.ok
    if (a.secret == null) return this.note(SECOND_CODE)
    const oc = ownerCheck(a.owner, this.activeNpub, this.accountNpubs)
    if (oc !== "ok") return this.note(refusalText(oc.split(":")[0]))
    // A device already known under another role is refused here, before anything is sent (Tron 1).
    const early = roleCheck(a.mesh, a.role, roleCheckList(pairedDevices(this.storage), a.role))
    if (early.startsWith("refuseOtherRole")) return this.note(refusalText("refuseOtherRole", { role: early.split(":")[1] }))
    this.busy = true
    try {
      const t = this.now(), ownSecret = newSecret()
      this.joiner = await PairingJoiner.start(a, this.ownHex, ownSecret, t)
      if (!this.joiner) return this.note(refusalText("badCode"))
      this.a = a
      const words = await checkWords(a.meshHex, this.ownHex, a.secret)
      const qr = build({ m: npubEncode(this.ownHex), n: this.name, r: ROLE, o: this.activeNpub, e: a.secret, b: ownSecret })
      this.closeListen = this.net.listen(this.ownHex, ev => this.onEvent(ev))
      const hello = await sealHello({ toHex: a.meshHex, content: helloJson({ s: a.secret, n: this.name, r: ROLE, o: this.activeNpub, t }), now: t, storage: this.storage })
      this.set({ step: "showBack", qr, name: a.name, role: a.role, words, address: shortAddress(a.mesh), waitWords: false, wordsTapped: false, expiresAt: t + ACK_WINDOW })
      // The same event until the ack: a changed hello would abort A's session (Tron 3).
      await this.sendKept(hello)
    } finally { this.busy = false }
  }

  async onEvent(ev) {
    if (!this.joiner) return
    const opened = await openHello(ev, { ownHex: this.ownHex, storage: this.storage })
    if (!opened) return
    this.after(this.joiner.receiveAck(opened.sender, opened.content, this.now()))
  }

  /** "They match", on this side (the other device accepted with the words). */
  confirmWords() {
    if (this.view.step !== "showBack") return
    const out = this.joiner.confirmWords(this.now())
    if (out === "waitAck") this.set({ ...this.view, wordsTapped: true })
    else this.after(out)
  }

  after(out) {
    if (out === "linked") {
      this.stop()
      this.set(this.roleStep(this.joiner.device))
    } else if (out === "waitWords") this.set({ ...this.view, waitWords: true })
    else if (out === "expired") this.end({ step: "expired", text: refusalText("expired") })
  }

  confirmRole() {
    if (this.view.step !== "confirm") return
    const device = this.view.device
    addPaired(device, { storage: this.storage, liveOwners: this.liveOwners })
    this.set({ step: "linked", device })
  }

  expire(t) {
    if (this.view.step === "showBack" && t - this.joiner.scannedAt > ACK_WINDOW) this.end({ step: "expired", text: refusalText("expired") })
  }
}
