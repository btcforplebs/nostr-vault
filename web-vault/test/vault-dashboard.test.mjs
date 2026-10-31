// The web Vault Dashboard (iPhone VaultDashboardView): the Vault button's colour rule, the sheet's address, and each
// section's numbers and wording, checked as data and as the vnodes the sections return. Nothing is drawn or fetched.
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
const { countContents, groupRows, sizeText, mediaBucket, kindName, COUNT_ROUTES, COUNTED_KINDS } = await import("../src/net/vault-contents.js")
const { readHistory, markRan, relative, monthYear } = await import("../src/net/vault-history.js")
const { activityItems, health, redact, report, bannerDetail } = await import("../src/net/relay-activity.js")
const { poolState, withGrace, STATES, DROP_GRACE_MS } = await import("../src/net/connection-color.js")
const { dashboardHref, isDashboardOpen } = await import("../src/net/dashboard-route.js")
const { SafetySection, keyRow } = await import("../src/components/dashboard/SafetySection.jsx")
const { ReachSection, blockedDetail } = await import("../src/components/dashboard/ReachSection.jsx")
const { headerDetail, storageParts } = await import("../src/components/dashboard/ContentsSection.jsx")
const { SettingsSection } = await import("../src/components/dashboard/SettingsSection.jsx")
const { KeepFullSection } = await import("../src/components/dashboard/KeepFullSection.jsx")
const { uptimeLine } = await import("../src/components/dashboard/StatusCard.jsx")

const ME = "a".repeat(64)
const memory = () => { const m = new Map(); return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) } }
// The Rows a section vnode holds, as { title, detail, state, href, value }.
const rows = section => [section.props.children].flat(3).filter(Boolean).map(v => v.props)

test("the Vault button colours as the iPhone's: connected green, connecting yellow (2 s grace), error red, else grey", () => {
  const pool = (relays, closing = 0) => ({ relays: new Map(relays.map((c, i) => [i, { connected: c }])), closing: new Set(Array.from({ length: closing }, (_, i) => i)) })
  assert.equal(poolState(pool([false, true])), "connected")
  assert.equal(poolState(pool([false])), "connecting")
  assert.equal(poolState(pool([], 2)), "error")
  assert.equal(poolState(pool([false]), false), "error", "the browser offline")
  assert.equal(poolState(pool([])), "disconnected")
  assert.deepEqual(Object.values(STATES).map(s => s.text), ["Connected", "Connecting...", "Connection Error", "Disconnected"])
  let g = withGrace(null, "connected", 0)
  g = withGrace(g, "connecting", 1000); assert.equal(g.shown, "connected", "a drop waits")
  g = withGrace(g, "connecting", 1000 + DROP_GRACE_MS - 1); assert.equal(g.shown, "connected")
  g = withGrace(g, "connecting", 1000 + DROP_GRACE_MS); assert.equal(g.shown, "connecting")
  assert.equal(withGrace(withGrace(null, "connected", 0), "error", 10).shown, "error", "an error shows at once")
})

test("the sheet is ?sheet=dashboard over whatever was open", () => {
  assert.equal(dashboardHref("#/vault/notes"), "#/vault/notes?sheet=dashboard")
  assert.equal(dashboardHref(""), "#/vault?sheet=dashboard")
  assert.equal(isDashboardOpen("#/feed?note=x&sheet=dashboard"), true)
  assert.equal(isDashboardOpen("#/vault"), false)
})

test("In your vault: COUNTs summed over the four routes, grouped and ordered as the phone", async () => {
  const asked = []
  const client = byKind => ({ count: async f => { asked.push(f); if (!f.kinds) return Object.values(byKind).reduce((a, b) => a + b, 0) + 3; if (f.authors) return f.kinds.reduce((n, k) => n + (byKind[k] ? 1 : 0), 0); return byKind[f.kinds[0]] ?? 0 } })
  const c = await countContents([client({ 1: 10, 7: 4, 1059: 2, 3: 1, 5: 1 }), client({ 1: 5, 30023: 2 })], ME)
  assert.equal(c.total, 31); assert.equal(c.byKind[1], 15)
  assert.equal(asked.filter(f => !f.kinds).length, 2, "one total per route")
  const r = groupRows(c)
  assert.deepEqual(r.map(x => [x.title, x.count, x.yours]), [["Notes", 15, 2], ["Articles", 2, 1], ["Reactions", 4, 1], ["Messages", 2, null], ["Profile and lists", 1, 1], ["Other", 7, null]])
  assert.deepEqual(r.at(-1).kinds.map(k => [kindName(k.kind), k.count]), [["Kinds not listed", 6], ["Deletions", 1]])
  assert.equal(await countContents([{ count: async () => { throw new Error("closed") } }], ME), null, "a route that doesn't answer: no numbers")
  assert.deepEqual(COUNT_ROUTES, ["/", "/inbox", "/private", "/chat"])
  assert.ok(COUNTED_KINDS.includes(30078))
  assert.equal(headerDetail(c, 5_200_000), "31 events · 5.2 MB")
  assert.equal(headerDetail(null, 0), "None")
  assert.deepEqual(storageParts(10_000, 3_000).map(p => [p.title, p.size]), [["Notes and data", 7000], ["Media", 3000]])
})

test("sizes as the phone writes them, and media typed by their first bytes", () => {
  assert.deepEqual([0, 512, 1500, 2_345_678, 1_200_000_000].map(sizeText), ["None", "512 bytes", "2 KB", "2.3 MB", "1.2 GB"])
  const b = (...x) => Uint8Array.from(x)
  const s = str => Uint8Array.from([...str].map(c => c.charCodeAt(0)))
  assert.equal(mediaBucket(b(0xff, 0xd8, 0xff, 0xe0)), "image")
  assert.equal(mediaBucket(b(0x89, 0x50, 0x4e, 0x47)), "image")
  assert.equal(mediaBucket(Uint8Array.from([0, 0, 0, 24, ...s("ftypisom")])), "video")
  assert.equal(mediaBucket(Uint8Array.from([0, 0, 0, 24, ...s("ftypavif")])), "image")
  assert.equal(mediaBucket(Uint8Array.from([0, 0, 0, 24, ...s("ftypM4A ")])), "audio")
  assert.equal(mediaBucket(b(0x1a, 0x45, 0xdf, 0xa3)), "video")
  assert.equal(mediaBucket(s("ID3\x04")), "audio")
  assert.equal(mediaBucket(s("%PDF")), "other")
})

test("Is it safe?: the key row by sign-in, follow list, backup file, N of 3", () => {
  assert.deepEqual(keyRow("nip46"), { title: "Your key is in a signer app", detail: "Nostr Vault asks it to sign.", done: true })
  assert.equal(keyRow("local").title, "Your key is on this device")
  assert.deepEqual(keyRow("readonly"), { title: "No key on this device", detail: "You can read, but not post or sign.", done: false })
  const none = SafetySection({ method: "readonly" })
  assert.equal(none.props.title, "Is it safe?"); assert.equal(none.props.detail, "0 of 3")
  const r = rows(none)
  assert.deepEqual(r.map(x => x.title), ["No key on this device", "Follow list saved", "Backup file"])
  assert.deepEqual(r.map(x => x.state), ["todo", "todo", "todo"])
  assert.equal(r[1].detail, "Not saved yet. If a client wipes it, you can't get it back.")
  assert.equal(r[2].detail, "Never made. Keep one somewhere off this device.")
  assert.equal(r[2].children.props.title, "Make one")
  const all = SafetySection({ method: "nip07", followSavedAt: Date.now() - 3600_000, backupAt: Date.now() - 86400_000 })
  assert.equal(all.props.detail, "3 of 3")
  assert.match(rows(all)[1].detail, /^Last saved 1 hour ago\.$/)
  assert.equal(rows(all)[2].children.props.title, "Make new")
})

test("Who can reach you and Vault settings: the phone's words, no Mac or relay-list rows", () => {
  const reach = rows(ReachSection({ trusted: 1234, blocked: 1 }))
  assert.deepEqual(reach.map(x => x.title), ["1,234 people can reach your inbox", "Blocked"])
  assert.equal(reach[0].detail, "People within 2 hops of you. Everyone else is kept out.")
  assert.equal(reach[1].detail, "1 person blocked.")
  assert.equal(rows(ReachSection({}))[0].title, "Trust list not built yet")
  assert.deepEqual([0, 1, 5].map(blockedDetail), ["Nobody blocked.", "1 person blocked.", "5 people blocked."])
  const set = rows(SettingsSection({ relays: 6, mediaServers: 2 }))
  assert.deepEqual(set.map(x => [x.title, x.value]), [["Relays", "6"], ["Who Can Reach You", "2 hops"], ["Media Servers", "2"]])
})

test("Keep it full: import notes since its start, media backup and notes export, no Import media", () => {
  const k = KeepFullSection({ startDate: "2023-01-01", history: {} })
  const r = rows(k)
  assert.deepEqual(r.map(x => x.title), ["Import notes", "Back up media", "Export notes"])
  assert.equal(r[0].detail, "Since Jan 2023. Never ran.")
  assert.deepEqual(r.slice(1).map(x => x.detail), ["Never made.", "Never made."])
  assert.deepEqual(r.map(x => x.children.props.title), ["Import", "Back up", "Export"])
  const running = rows(KeepFullSection({ startDate: "2023-01-01", importing: { progress: 0.5, text: "Found notes from 2024-01-01... (3 found)" } }))
  assert.equal(running[0].progress, 0.5); assert.equal(running[1].children.props.disabled, true, "one job at a time")
})

test("history: per account, and the phone's relative words", () => {
  const s = memory()
  markRan(ME, "notesBackup", 1000, s)
  assert.deepEqual(readHistory(ME, s), { notesBackup: 1000 })
  assert.deepEqual(readHistory("b".repeat(64), s), {})
  const now = Date.UTC(2026, 9, 28, 12)
  assert.equal(relative(now - 2 * 3600_000, now, "en"), "2 hours ago")
  assert.equal(relative(now - 86400_000, now, "en"), "yesterday")
  assert.equal(relative(now, now, "en"), "now")
  assert.equal(monthYear("2023-01-01"), "Jan 2023")
  assert.equal(uptimeLine(0, 3 * 86400_000 + 4 * 3600_000), "Up 3d 4h")
  assert.equal(uptimeLine(0, 2 * 3600_000 + 5 * 60_000), "Up 2h 5m")
  assert.equal(uptimeLine(0, 7 * 60_000), "Up 7m")
})

test("relay activity: the log as plain lines, health from the newest, reports without keys, ids, IPs or paths", () => {
  const log = [
    { t: "2026-10-28T10:00:00Z", type: "boot", loadMs: 300, startMs: 120 },
    { t: "2026-10-28T10:00:01Z", type: "persist", granted: false },
    { t: "2026-10-28T10:00:02Z", type: "noise" },
  ]
  const items = activityItems(log)
  assert.deepEqual(items.map(i => [i.level, i.text]), [["good", "Your vault started in 420 ms"], ["headsUp", "This browser may clear your vault when it needs room"]])
  assert.equal(health(items), "headsUp")
  assert.equal(bannerDetail(items), "This browser may clear your vault when it needs room")
  assert.equal(health(activityItems([{ t: "x", type: "boot-error", err: "quota" }])), "problem")
  assert.equal(bannerDetail(activityItems(log.slice(0, 1))), "Your vault is running normally.")
  assert.equal(redact(`key npub1${"q".repeat(58)} id ${"f".repeat(64)} at 192.168.4.99 in /Users/logen/x`), "key [key] id [id] at [ip] in [path]")
  assert.match(report(items, { now: new Date(0) }), /Health: Heads-up/)
})
