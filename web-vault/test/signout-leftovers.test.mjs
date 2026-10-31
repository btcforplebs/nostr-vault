// Sign-out takes the account's leftovers with it (iPhone ResetLeftovers): every "<name>:<pubkey>" key, its feed-sync
// mark and the notifications showing. Removing another account does the same for that one. Reset Everything
// (iPhone Factory Reset) takes every account, this app's settings and the keyring, and asks first.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { forgetThisBrowser, accountKeys } = await import("../src/haven/vault.js")
const { removeAccount } = await import("../src/signer/accounts.js")
const { resetEverything, isAppKey, RESET_ALL_QUESTION } = await import("../src/net/reset-all.js")
const { saveSession, rememberAccount, loadAccounts } = await import("../src/session.js")
const { markSynced, syncedRecently } = await import("../src/net/feed-synced.js")

/** localStorage as the browser has it, with length and key(i). */
function storage() {
  const m = new Map()
  return { m, get length() { return m.size }, key: i => [...m.keys()][i] ?? null, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}
const idb = () => { const deleted = []; return { deleted, deleteDatabase(name) { const req = {}; setTimeout(() => { deleted.push(name); req.onsuccess?.() }); return req } } }
const ME = "a".repeat(64), OTHER = "b".repeat(64), THIRD = "c".repeat(64)
const LEFTOVERS = ["nv-vault-seen", "nv-vault-history", "nv-notify-mark", "nv-notify-since", "nv-notify-dm-mark", "nv-vault-followers-seen", "nv-vault-follower-lists", "nv-dm-read", "nv-never-connect", "nv-gallery-servers"]
const fill = (s, pk) => { for (const k of LEFTOVERS) s.setItem(`${k}:${pk}`, "x") }

test("sign-out deletes this account's leftovers, its feed-sync mark and the notifications showing; not another's", async () => {
  const s = storage(), session = storage()
  saveSession({ method: "nip07", pubkey: ME }, s)
  fill(s, ME); fill(s, OTHER)
  s.setItem(`nv-relay:x:${ME}`, "relay page's") // /relay/ is the same origin: never touched
  markSynced(ME, ["f"], { storage: session }); markSynced(OTHER, ["f"], { storage: session })
  let closed = 0
  const sw = { getRegistration: async () => ({ getNotifications: async () => [{ close: () => closed++ }, { close: () => closed++ }] }) }
  assert.equal(accountKeys(ME, s).length, LEFTOVERS.length)
  const { failed } = await forgetThisBrowser({ vault: null, pubkey: ME, storage: s, idb: idb(), session, sw })
  assert.deepEqual(failed, [])
  assert.deepEqual([...s.m.keys()].filter(k => k.endsWith(ME)), [`nv-relay:x:${ME}`])
  assert.equal(accountKeys(OTHER, s).length, LEFTOVERS.length, "another account's keys stay")
  assert.equal(syncedRecently(ME, ["f"], { storage: session }), false)
  assert.equal(syncedRecently(OTHER, ["f"], { storage: session }), true)
  assert.equal(closed, 2)
})

test("removing another account deletes its leftovers too", async () => {
  const s = storage()
  saveSession({ method: "nip07", pubkey: ME }, s)
  rememberAccount({ method: "nip07", pubkey: OTHER }, s)
  fill(s, ME); fill(s, OTHER)
  await removeAccount({ account: { method: "nip07", pubkey: OTHER }, pool: null, storage: s, idb: idb(), session: storage() })
  assert.equal(accountKeys(OTHER, s).length, 0)
  assert.equal(accountKeys(ME, s).length, LEFTOVERS.length)
})

test("Reset Everything removes every account, this app's settings and the keyring; /relay/'s keys stay", async () => {
  const s = storage(), session = storage(), db = idb()
  saveSession({ method: "nip07", pubkey: ME }, s)
  rememberAccount({ method: "nip07", pubkey: OTHER }, s)
  rememberAccount({ method: "nip46", pubkey: THIRD, bunker: "bunker://x" }, s)
  fill(s, ME); fill(s, OTHER); fill(s, THIRD)
  for (const k of ["post.sendDelaySeconds", "media.autoplayVideos", "display.compactLineLimit", "nv-notify-types", "nv-browser-notify", "nv-feed"]) s.setItem(k, "x")
  s.setItem("nv-relay:fips-owners", "relay page's"); s.setItem("unrelated", "keep")
  session.setItem("nv-feed-synced", "{}")
  let revokes = 0
  const out = await resetEverything({ vault: null, pubkey: ME, pool: null, storage: s, idb: db, session, waitMs: 50, sw: {},
    signerFor: () => ({ revoke: async () => { revokes++; return false } }) })
  assert.deepEqual(out.failed, [])
  assert.equal(out.revokeFailed, 1, "the bunker account was asked and didn't confirm")
  assert.equal(revokes, 1)
  assert.deepEqual(loadAccounts(s), [])
  assert.deepEqual([...s.m.keys()].sort(), ["nv-relay:fips-owners", "unrelated"])
  assert.equal(session.getItem("nv-feed-synced"), null)
  assert.ok(db.deleted.includes("nv-keyring"))
  for (const pk of [ME, OTHER, THIRD]) assert.ok(db.deleted.includes(`haven:${pk}:outbox`), pk)
  assert.equal(isAppKey("nv-relay:x"), false)
  assert.equal(isAppKey("display.threadedLineLimit"), true)
})

test("Reset Everything asks first, in the iPhone's terms, and only an explicit { all: true } resets everything", async () => {
  const { resetAll } = await import("../src/screens/SettingsScreen.jsx")
  const calls = []
  const ctx = { signOut: o => calls.push(o) }
  let asked = ""
  assert.equal(resetAll(ctx, q => { asked = q; return false }), false)
  assert.deepEqual(calls, [])
  assert.equal(asked, RESET_ALL_QUESTION)
  assert.match(RESET_ALL_QUESTION, /every account on this browser.*can't be recovered/s)
  assert.equal(resetAll(ctx, () => true), true)
  assert.deepEqual(calls, [{ all: true }])
  const main = readFileSync(new URL("../main.jsx", import.meta.url), "utf8")
  assert.match(main, /const all = opts\?\.all === true/)
})
