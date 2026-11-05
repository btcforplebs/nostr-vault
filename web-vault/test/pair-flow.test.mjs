// Two browsers pairing end to end through a fake relay: the web pair flows (pair-flow.js) on the real phase-0
// sessions, the real kind-21195 sealing (pair-hello.js) and the real store (pair-devices.js). Throwaway keys only.
import { test } from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { ShowFlow, ScanFlow, NOT_THEIR_CODE, SECOND_CODE } from "../src/net/pair-flow.js"
import { pairedDevices } from "../src/net/pair-devices.js"
import { refusalText, parse, build, newSecret } from "../src/net/mesh-pairing.js"
import { sealHello } from "../src/net/pair-hello.js"

const memStorage = () => { const m = new Map(); return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const settle = () => new Promise(r => setTimeout(r, 20))

/** A relay: everything sent reaches every listener for its p tag; `log` keeps each send. */
function bus() {
  const subs = new Set(), log = []
  return {
    log,
    net: {
      send: async ev => { log.push(ev); for (const s of [...subs]) if (ev.tags.some(t => t[0] === "p" && t[1] === s.hex)) s.cb(ev); return 1 },
      listen: (hex, cb) => { const s = { hex, cb }; subs.add(s); return () => subs.delete(s) },
    },
    get listeners() { return subs.size },
  }
}

function pair({ ownerA, ownerB = ownerA, accountsB } = {}) {
  const account = getPublicKey(generateSecretKey())
  const b = bus()
  let clock = 1_000_000
  const now = () => clock
  const sa = memStorage(), sb = memStorage()
  const liveA = new Set(), liveB = new Set()
  const A = new ShowFlow({ account: ownerA ?? account, accounts: [ownerA ?? account], name: "Chrome on Mac", storage: sa, liveOwners: liveA, net: b.net, now })
  const B = new ScanFlow({ account: ownerB ?? account, accounts: accountsB ?? [ownerB ?? account], name: "Firefox on Linux", storage: sb, liveOwners: liveB, net: b.net, now })
  return { A, B, b, sa, sb, liveA, liveB, step: s => { clock += s }, now }
}

test("scan path: both sides link, each stores the other only after its role confirm", async () => {
  const { A, B, b, sa, sb, liveA, liveB } = pair()
  await A.start(); await B.start()
  assert.equal(A.view.step, "showing")
  assert.match(A.view.qr, /^nvpair:v1\?m=npub1.*&n=Chrome%20on%20Mac&r=browser&o=npub1.*&s=/)
  await B.scanned(A.view.qr); await settle()
  assert.equal(B.view.step, "showBack")
  assert.equal(A.view.step, "scanBack")
  assert.equal(A.view.name, "Firefox on Linux")
  assert.deepEqual(A.view.words, B.view.words)
  assert.equal(pairedDevices(sa).length + pairedDevices(sb).length, 0, "nothing stored yet")
  A.scanned(B.view.qr); await settle()
  assert.equal(A.view.step, "confirm")
  assert.equal(A.view.text, "Add Firefox on Linux as your browser vault: it gets your new notes while it's open.")
  assert.equal(pairedDevices(sa).length, 0, "not before the role confirm")
  assert.equal(B.view.step, "showBack", "no ack before A stores")
  await A.confirmRole(); await settle()
  assert.equal(A.view.step, "linked")
  assert.deepEqual(pairedDevices(sa).map(d => [d.name, d.role]), [["Firefox on Linux", "browser"]])
  assert.equal(liveA.size, 1)
  assert.equal(B.view.step, "confirm")
  assert.equal(pairedDevices(sb).length, 0)
  B.confirmRole()
  assert.equal(B.view.step, "linked")
  assert.deepEqual(pairedDevices(sb).map(d => [d.name, d.role]), [["Chrome on Mac", "browser"]])
  assert.equal(pairedDevices(sb)[0].hex, A.ownHex, "B stored A's mesh address")
  assert.equal(pairedDevices(sa)[0].hex, B.ownHex, "A stored B's mesh address")
  assert.deepEqual([...liveA], [B.ownHex])
  assert.equal(liveB.size, 1)
  assert.equal(b.listeners, 0, "both stopped listening")
})

test("B resends its hello byte for byte; A ignores the resend", async () => {
  const { A, B, b, step } = pair()
  await A.start(); await B.start()
  await B.scanned(A.view.qr); await settle()
  step(5); B.tick(); await settle()
  step(5); B.tick(); await settle()
  const hellos = b.log.filter(e => e.pubkey !== b.log[0].tags[0][1])
  assert.ok(hellos.length >= 3)
  assert.ok(hellos.every(e => JSON.stringify(e) === JSON.stringify(hellos[0])))
  assert.equal(A.view.step, "scanBack")
})

test("a second, different hello for the same code aborts A (Tron 3)", async () => {
  const { A, B, b } = pair()
  await A.start(); await B.start()
  const codeA = A.view.qr
  await B.scanned(codeA); await settle()
  // A stranger who photographed A's code races in with its own hello.
  const s2 = memStorage()
  const C = new ScanFlow({ account: B.account, accounts: [B.account], name: "Stranger", storage: s2, net: b.net, now: B.now })
  await C.start(); await C.scanned(codeA)
  await settle()
  assert.equal(A.view.step, "aborted")
  assert.equal(A.view.text, refusalText("abort"))
})

test("Accept path: words on both sides, B stores only after its own tap", async () => {
  const { A, B, sb } = pair()
  await A.start(); await B.start()
  await B.scanned(A.view.qr); await settle()
  A.accept(); assert.equal(A.view.step, "scanBack", "Accept needs a browser with no camera")
  A.noCamera(); assert.equal(A.view.cameraOff, true)
  A.accept(); assert.equal(A.view.step, "confirm")
  await A.confirmRole(); await settle()
  assert.equal(B.view.step, "showBack")
  assert.equal(B.view.waitWords, true)
  assert.equal(pairedDevices(sb).length, 0)
  B.confirmWords()
  assert.equal(B.view.step, "confirm")
  B.confirmRole()
  assert.equal(pairedDevices(sb).length, 1)
})

test("B's tap before the words ack still waits for the ack", async () => {
  const { A, B } = pair()
  await A.start(); await B.start()
  await B.scanned(A.view.qr); await settle()
  B.confirmWords(); assert.equal(B.view.wordsTapped, true); assert.equal(B.view.step, "showBack")
  A.noCamera(); A.accept(); await A.confirmRole(); await settle()
  assert.equal(B.view.step, "confirm")
})

test("A's code expires after 3 minutes; B gives up 6 minutes after its scan", async () => {
  const p = pair()
  await p.A.start(); p.step(181); p.A.tick()
  assert.equal(p.A.view.step, "expired")
  assert.equal(p.A.view.text, "This code has expired. Show a new one.")
  const q = pair()
  await q.A.start(); await q.B.start(); await q.B.scanned(q.A.view.qr); await settle()
  q.step(181); q.A.tick(); assert.equal(q.A.view.step, "expired", "scan window")
  q.step(180); q.B.tick(); assert.equal(q.B.view.step, "expired", "ack window")
})

test("refusals: another owner, a reply code, the wrong code back, a device under another role", async () => {
  const other = getPublicKey(generateSecretKey())
  const p = pair({ ownerA: getPublicKey(generateSecretKey()), ownerB: other })
  await p.A.start(); await p.B.start()
  await p.B.scanned(p.A.view.qr)
  assert.equal(p.B.view.step, "scanning")
  assert.equal(p.B.view.notice, refusalText("otherOwner"))
  await p.B.scanned("hello")
  assert.equal(p.B.view.notice, refusalText("notPairing"))

  const q = pair()
  await q.A.start(); await q.B.start(); await q.B.scanned(q.A.view.qr); await settle()
  const replyCode = q.B.view.qr
  const r = pair()
  await r.B.start(); await r.B.scanned(replyCode)
  assert.equal(r.B.view.notice, SECOND_CODE)
  assert.equal(q.A.view.step, "scanBack")
  // A reply code that echoes A's secret but comes from another mesh address is not the device that said hello.
  q.A.scanned(build({ ...fieldsOf(replyCode), m: npubEncode(getPublicKey(generateSecretKey())) }))
  assert.equal(q.A.view.notice, NOT_THEIR_CODE)
  assert.equal(q.A.view.step, "scanBack", "A keeps scanning")
  q.A.scanned(replyCode); await settle()
  assert.equal(q.A.view.step, "confirm")
})

test("a device known under another role is refused before anything is sent", async () => {
  const p = pair()
  await p.A.start(); await p.B.start()
  const aHex = parse(p.A.view.qr).ok.meshHex
  p.sb.setItem("nv-vault:fips-owners", aHex)
  p.sb.setItem("nv-vault:fips-owner-meta", JSON.stringify({ [aHex]: { name: "x", role: "homeVault" } }))
  const before = p.b.log.length
  await p.B.scanned(p.A.view.qr)
  assert.equal(p.B.view.notice, "This device is already added as your home vault. Remove it in Mesh settings first.")
  assert.equal(p.b.log.length, before)
})

test("cancelling at the role confirm stores nothing and sends no ack", async () => {
  const { A, B, b, sa } = pair()
  await A.start(); await B.start(); await B.scanned(A.view.qr); await settle()
  A.scanned(B.view.qr); await settle()
  assert.equal(A.view.step, "confirm")
  const sent = b.log.length
  A.stop()
  assert.equal(pairedDevices(sa).length, 0)
  assert.equal(b.log.length, sent)
})

function fieldsOf(code) {
  const p = parse(code).ok
  return { m: p.mesh, n: p.name, r: p.role, o: p.owner, e: p.echo, b: p.bSecret }
}
