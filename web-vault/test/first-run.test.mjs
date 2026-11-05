// Web first run (net/first-run.js, Logen's plan 2026-11-05): the two questions' words, the tour shown once per new
// account, and the notification question asked once, after you're in, never over the tour.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { NEW_TO_NOSTR, NEW_TO_NOSTR_YES, NEW_TO_NOSTR_NO, TOUR, tourDone, markTourDone, notifyAction, notifyAsked, markNotifyAsked, QUIET_MS, NOTIFY_ASKED } from "../src/net/first-run.js"
import { QUESTION, RELAYS, COPY, LOST_DEVICE } from "../src/net/setup-bring-over.js"

const mem = () => { const m = new Map(); return { m, get length() { return m.size }, key: i => [...m.keys()][i] ?? null, getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const src = f => readFileSync(new URL(`../${f}`, import.meta.url), "utf8")

test("setup is two questions, in the apps' words; the backup zip left setup", () => {
  assert.deepEqual([NEW_TO_NOSTR, NEW_TO_NOSTR_YES, NEW_TO_NOSTR_NO], ["New to Nostr?", "Yes, create an account", "No, I already use Nostr"])
  assert.deepEqual([QUESTION, RELAYS, COPY], ["New to Nostr Vault?", "Yes, bring my notes from relays", "No, copy from my other vault"])
  assert.equal(LOST_DEVICE, "Lost your other device? We'll bring your notes from relays")
  const welcome = src("src/screens/WelcomeScreen.jsx")
  assert.ok(welcome.includes("{NEW_TO_NOSTR}") && welcome.indexOf("{NEW_TO_NOSTR}") < welcome.indexOf("{NEW_TO_NOSTR_YES}"))
  const setup = src("src/screens/SetupBringOver.jsx")
  assert.ok(!/type="file"|restoreSetupBackup|BACKUP/.test(setup), "no backup restore in setup")
  assert.match(src("src/components/dashboard/KeepFullSection.jsx"), /title="Restore from a backup" href="#\/settings\/backup"/)
})

test("who showed you this app is only on the create-account path, and adds them to the follows", () => {
  const create = src("src/screens/CreateAccount.jsx")
  assert.match(create, /"profile", "referrer", "follows"/)
  assert.match(create, /<ReferrerStep onFollow=\{pk => \{ setPicked\(s => new Set\(\[\.\.\.s, pk\]\)\); next\(\) \}\} onSkip=\{next\} \/>/)
  assert.ok(!/ReferrerStep/.test(src("src/screens/SignInScreen.jsx")), "not for someone who already uses Nostr")
  assert.ok(!/ReferrerStep/.test(src("src/screens/SetupBringOver.jsx")))
})

test("the tour: once per new account, kept per account so sign-out forgets it", async () => {
  const { accountKeys } = await import("../src/haven/vault.js")
  const s = mem(), A = "a".repeat(64), B = "b".repeat(64)
  assert.equal(tourDone(A, s), false)
  markTourDone(A, s)
  assert.equal(tourDone(A, s), true)
  assert.equal(tourDone(B, s), false)
  assert.ok(accountKeys(A, s).includes(`nv-tour-done:${A}`))
  assert.equal(TOUR.length, 3)
  const main = src("main.jsx")
  assert.match(main, /if \(madeHere && !tourDone\(session\.pubkey\)\) setTour\(true\)/, "only an account made here")
  assert.match(main, /<NotifyAsk busy=\{tour\} \/>/, "the notification question waits for the tour")
})

test("the notification question: once, after you're in, never over the tour, after 2 s of quiet", () => {
  const base = { permission: "default", asked: false, inApp: true, busy: false, quietForMs: QUIET_MS }
  assert.equal(notifyAction(base), "ask")
  assert.equal(notifyAction({ ...base, inApp: false }), "wait", "not before you're in")
  assert.equal(notifyAction({ ...base, busy: true }), "wait", "never over the tour")
  assert.equal(notifyAction({ ...base, quietForMs: QUIET_MS - 1 }), "wait", "the tour just closed: a moment first")
  assert.equal(notifyAction({ ...base, asked: true }), "answered", "asked once")
  for (const p of ["granted", "denied", "unsupported"]) assert.equal(notifyAction({ ...base, permission: p }), "answered", p)
  const s = mem()
  assert.equal(notifyAsked(s), false)
  markNotifyAsked(s)
  assert.equal(notifyAsked(s), true)
  assert.equal(s.getItem(NOTIFY_ASKED), "1")
  // The switch follows the answer: Turn on asks the browser from the tap (turnOn), Not now leaves it off.
  const ask = src("src/components/NotifyAsk.jsx")
  assert.match(ask, /const answer = async on => \{ markNotifyAsked\(\); setShow\(false\); if \(on\) await turnOn\(\)/)
  assert.ok(!/requestPermission/.test(ask), "never asks the browser without the tap")
  assert.match(ask, /useEffect\(\(\) => \{ quietSince\.current = Date\.now\(\) \}, \[busy\]\)/, "the 2 s count from when the tour closes")
})
