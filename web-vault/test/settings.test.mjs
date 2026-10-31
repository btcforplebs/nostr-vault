// Settings: the phone's groups trimmed to the web's rows, the relay and media-server lists as the account publishes
// them, a backup read in pages and written as JSON lines, and a restore that takes only the user's own signed
// events. Throwaway keys and a fake outbox: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import {
  SETTINGS_GROUPS, PAGES, isPage, APP_VERSION, SUPPORT_NPUB, relayRows, mediaServerRows, APP_COMMIT, commitUrl,
  parseBackup, restoreBackup, logLines,
} from "../src/net/settings.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { resetBrowser, RESET_QUESTION, RESET_KEY_WARNING } = await import("../src/screens/SettingsScreen.jsx")

const SK = generateSecretKey(), ME = getPublicKey(SK)
const OTHER_SK = generateSecretKey(), OTHER = getPublicKey(OTHER_SK)
const signed = (sk, kind, content, created_at = 1000) => finalizeEvent({ kind, content, tags: [], created_at }, sk)

test("groups are the phone's, each row with a page or a screen to go to; every settings page is a row", () => {
  assert.deepEqual(SETTINGS_GROUPS.map(g => g.title), ["Account", "Relays", "Your Vault Relay", "Advanced"])
  const rows = SETTINGS_GROUPS.flatMap(g => g.rows)
  assert.equal(rows.find(r => r.id === "accounts").href, "#/accounts")
  // The phone's row titles and tile colours (SettingsView.SettingsTab, iconBackgroundColor)
  assert.equal(rows.find(r => r.id === "accounts").title, "Accounts & Keys")
  assert.equal(rows.find(r => r.id === "following-backup").color, "#40c8e0") // teal
  assert.equal(rows.find(r => r.id === "relays").color, "var(--accent)") // havenPurple is the accent
  assert.equal(rows.find(r => r.id === "relay-access").href, "#/relay")
  assert.equal(rows.find(r => r.id === "wallet").href, "#/wallet")
  for (const r of rows) assert.match(r.href, /^#\/[a-z-]+(\/[a-z-]+)?$/)
  assert.deepEqual(Object.keys(PAGES).sort(), ["backup", "blocked", "database", "following-backup", "import", "logs", "media-servers", "recently-deleted", "relays"])
  assert.ok(isPage("backup") && !isPage("accounts") && !isPage("") && !isPage(undefined) && !isPage("constructor"))
  assert.match(APP_VERSION, /^\d+\.\d+\.\d+/)
  assert.match(SUPPORT_NPUB, /^npub1/)
})

test("About's commit: none in Node, linked only when it's a clean commit id", () => {
  assert.equal(APP_COMMIT, "")
  assert.equal(commitUrl("63059b4702c2"), "https://github.com/btcforplebs/nostr-vault/commit/63059b4702c2")
  assert.equal(commitUrl("63059b4702c2-dirty"), "")
  assert.equal(commitUrl("latest"), "")
  assert.equal(commitUrl(""), "")
})

test("relay rows carry each relay's read and write marks; no list means no rows", () => {
  const ev = { kind: 10002, tags: [["r", "wss://a.io"], ["r", "wss://b.io/", "read"], ["r", "wss://c.io", "write"], ["r", "wss://nos.lol"]] }
  assert.deepEqual(relayRows(ev), [{ url: "wss://a.io", read: true, write: true }, { url: "wss://b.io", read: true, write: false }, { url: "wss://c.io", read: false, write: true }])
  assert.deepEqual(relayRows(undefined), [])
})

test("media servers: the account's list when it has one, else the defaults marked as such", () => {
  const rows = mediaServerRows({ kind: 10063, tags: [["server", "https://cdn.example/"]] })
  assert.deepEqual(rows, [{ url: "https://cdn.example", listed: true }])
  assert.ok(mediaServerRows(undefined).every(r => !r.listed && /^https:/.test(r.url)))
})

test("a restore takes only events that verify and were signed by the user, from JSON lines or an array", () => {
  const good = signed(SK, 1, "mine"), theirs = signed(OTHER_SK, 1, "theirs")
  const forged = { ...signed(SK, 1, "x"), content: "changed" }
  const text = [JSON.stringify(good), "not json", JSON.stringify(theirs), JSON.stringify(forged), JSON.stringify(good), "", "42"].join("\n")
  const r = parseBackup(text, ME)
  assert.deepEqual(r.events.map(e => e.id), [good.id])
  assert.deepEqual(r.skipped, { unreadable: 2, badSignature: 1, notYours: 1 })
  const arr = parseBackup(JSON.stringify([good, theirs]), ME)
  assert.equal(arr.events.length, 1)
  assert.equal(arr.skipped.notYours, 1)
  assert.deepEqual(parseBackup("[oops", ME), { events: [], skipped: { unreadable: 1, badSignature: 0, notYours: 0 } })
  assert.deepEqual(parseBackup("", ME).events, [])
})

test("restoreBackup counts stored, already-there and refused, and reports progress", async () => {
  const a = signed(SK, 1, "a"), b = signed(SK, 1, "b", 1001), c = signed(SK, 1, "c", 1002)
  const answers = { [a.id]: { ok: true }, [b.id]: { ok: false, message: "duplicate: already have this event" }, [c.id]: { ok: false, message: "blocked: nope" } }
  const vault = { outbox: { event: async ev => answers[ev.id] } }
  const seen = []
  const r = await restoreBackup(vault, [a, b, c], { onProgress: p => seen.push(p.done) })
  assert.equal(r.stored, 1)
  assert.equal(r.duplicate, 1)
  assert.deepEqual(r.refused, [{ id: c.id, message: "blocked: nope" }])
  assert.deepEqual(seen, [1, 2, 3])
  const thrown = await restoreBackup({ outbox: { event: async () => { throw new Error("gone") } } }, [a])
  assert.equal(thrown.refused[0].message, "gone")
})

test("log lines show the time, the type and the rest", () => {
  assert.deepEqual(logLines([{ t: "T", type: "boot", loadMs: 5 }]), ['T  boot  {"loadMs":5}'])
  assert.deepEqual(logLines([]), [])
})

test("Database & Reset asks first, naming what goes; Cancel wipes nothing", () => {
  let wiped = 0, asked = ""
  const ctx = { signOut: () => wiped++, session: { method: "nip07" } }
  assert.equal(resetBrowser(ctx, q => { asked = q; return false }), false)
  assert.equal(wiped, 0)
  assert.equal(asked, RESET_QUESTION)
  assert.match(RESET_QUESTION, /notes, messages, drafts and paired vaults/)
  assert.equal(resetBrowser(ctx, () => true), true)
  assert.equal(wiped, 1)
  // A key made in this browser is deleted with it: the question says so.
  resetBrowser({ ...ctx, session: { method: "local" } }, q => { asked = q; return false })
  assert.equal(asked, `${RESET_QUESTION} ${RESET_KEY_WARNING}`)
})

// Signing out wipes this browser's copy, so every Sign out asks first: the Relay screen and the sidebar menu through
// resetBrowser, Accounts with its own Sign out / Cancel row. None calls ctx.signOut straight from a click.
test("every Sign out button asks before the wipe", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  for (const f of ["screens/RelayScreen.jsx", "desktop/Sidebar.jsx"]) {
    assert.match(src(f), /onClick=\{\(\) => resetBrowser\(ctx\)\}>Sign out</, f)
  }
  const accounts = src("screens/AccountsScreen.jsx")
  assert.match(accounts, /onClick=\{\(\) => setConfirm\(true\)\}>Sign out</)
  for (const f of ["screens/RelayScreen.jsx", "desktop/Sidebar.jsx", "screens/SettingsScreen.jsx", "screens/AccountsScreen.jsx"]) {
    const direct = (src(f).match(/onClick=\{ctx\.signOut\}/g) ?? []).length
    assert.equal(direct, f.includes("Accounts") ? 1 : 0, `${f}: the only direct one is Accounts' confirm row`)
  }
  // The Unlock screen (a locked browser key): both its Sign out buttons ask through resetBrowser.
  const main = readFileSync(new URL("../main.jsx", import.meta.url), "utf8")
  assert.match(main, /const leave = \(\) => resetBrowser\(\{ session, signOut: onSignOut \}\)/)
  assert.equal((main.match(/onClick=\{leave\}>Sign out/g) ?? []).length, 2)
  assert.doesNotMatch(main, /onClick=\{onSignOut\}/)
})

test("a backup file is the phone's .zip by its bytes, anything else an older .jsonl", async () => {
  const { isZip } = await import("../src/components/BackupCard.jsx")
  assert.equal(isZip(new Uint8Array([0x50, 0x4b, 3, 4, 20])), true)
  assert.equal(isZip(new TextEncoder().encode('{"id":"x"}\n')), false)
  assert.equal(isZip(new Uint8Array([0x50, 0x4b])), false)
})
