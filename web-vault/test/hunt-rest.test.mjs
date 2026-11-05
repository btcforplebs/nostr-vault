// Web bug hunt 2026-11-05 fixes (RESEARCH/NV_BUG_HUNT_WEB_2026_11_05.md #2, #8, #10, two-tab layout edits, Reset
// Everything's settings). Throwaway keys only; nothing reaches a relay.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const mem = (entries = []) => {
  const m = new Map(entries)
  return { m, get length() { return m.size }, key: i => [...m.keys()][i] ?? null, getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}
const A = "a".repeat(64), B = "b".repeat(64)
const signedIn = (s, pk) => s.setItem("nv-session", JSON.stringify({ method: "readonly", pubkey: pk }))

test("#2: recent searches belong to the account: sign-out removes them, the next account doesn't see them", async () => {
  const { saveRecent, loadRecent } = await import("../src/net/search.js")
  const { accountKeys } = await import("../src/haven/vault.js")
  const s = mem([["nv.search.recent", JSON.stringify(["from before"])]])
  signedIn(s, A)
  saveRecent(s, "alice's search")
  assert.deepEqual(loadRecent(s), ["alice's search"])
  assert.equal(s.getItem("nv.search.recent"), null, "the old unattributed list is dropped")
  assert.ok(accountKeys(A, s).includes(`nv.search.recent:${A}`), "sign-out's sweep finds it")
  signedIn(s, B)
  assert.deepEqual(loadRecent(s), [], "B sees none of A's")
})

test("#2: recently played music artists belong to the account too", async () => {
  const wl = await import("../src/readers/wavlake.js")
  const { accountKeys } = await import("../src/haven/vault.js")
  const s = mem()
  signedIn(s, A)
  wl.rememberRecent({ id: "artist-1", name: "A's band" }, s)
  assert.equal(wl.loadRecent(s)[0].name, "A's band")
  assert.ok(accountKeys(A, s).includes(`nv-music-recent-artists:${A}`))
  signedIn(s, B)
  assert.deepEqual(wl.loadRecent(s), [])
})

test("#8: on desktop, a note opened while on Messages opens beside the Feed", async () => {
  const { deskRedirect } = await import("../src/desktop/routes.js")
  const id = "c".repeat(64)
  assert.equal(deskRedirect(`#/thread/${id}`, `#/messages?dm=${B}`), `#/feed?note=${id}`)
  assert.equal(deskRedirect(`#/thread/${id}`, "#/messages/requests"), `#/feed?note=${id}`)
  assert.equal(deskRedirect(`#/thread/${id}`, "#/vault"), `#/vault?note=${id}`, "other lists keep it beside them")
})

test("#10: the rail neither offers nor draws feed pins the web has no feed for; the rest are all real feeds", async () => {
  const { FEED_NAME } = await import("../src/desktop/rail/RailFavs.jsx").catch(() => ({}))
  const { webHasFeedPin, NOT_ON_WEB, feedPinToWeb } = await import("../src/desktop/rail/rail-favs.js")
  const { FEEDS } = await import("../src/net/feeds.js")
  // The web's feeds: net/feeds.js FEEDS plus the readers (read from source: readers/index.js imports screens).
  const readers = [...readFileSync(new URL("../src/readers/index.js", import.meta.url), "utf8").matchAll(/\{ id: "([a-z]+)"/g)].map(m => m[1])
  const web = new Set([...FEEDS.map(f => f.id), ...readers])
  assert.ok(readers.includes("music"), "positive control: the readers were read")
  const names = FEED_NAME ?? Object.fromEntries([...readFileSync(new URL("../src/desktop/rail/RailFavs.jsx", import.meta.url), "utf8")
    .match(/FEED_NAME = \{([^}]+)\}/)[1].matchAll(/([a-z]+): "/g)].map(m => [m[1], 1]))
  for (const id of Object.keys(names)) {
    if (NOT_ON_WEB.has(id)) assert.ok(!web.has(feedPinToWeb(id)) && !webHasFeedPin({ type: "feed", id }), id)
    else assert.ok(web.has(feedPinToWeb(id)) && webHasFeedPin({ type: "feed", id }), `${id} is a web feed`)
  }
  assert.ok(webHasFeedPin({ type: "section", id: "feed" }))
})

test("two tabs: an edit in one starts from what the other tab saved, instead of writing over it", async () => {
  globalThis.localStorage = mem()
  const { changeLayout, currentLayout } = await import("../src/desktop/space/layout-store.js")
  const { readLayout, writeLayout, setPins } = await import("../src/desktop/space/space-layout.js")
  const { PANEL_IDS } = await import("../src/desktop/space/panel-ids.js")
  const { pin, favourite } = await import("../src/desktop/rail/rail-favs.js")
  const me = "d".repeat(64)
  const start = currentLayout(me) // this tab's copy, read now
  // The other tab pins a hashtag and saves it.
  const other = setPins(start, pin(start.pins, favourite("hashtag", "nostr")), (start.at ?? 0) + 5)
  writeLayout(me, other)
  // This tab then turns a panel off.
  const id = start.panels[0].id
  changeLayout(me, l => ({ ...l, at: (l.at ?? 0) + 10, panels: l.panels.map(p => (p.id === id ? { ...p, on: false } : p)) }))
  const now = readLayout(me, PANEL_IDS)
  assert.ok(now.pins.some(p => p.type === "hashtag" && p.t === "nostr"), "the other tab's pin survived")
  assert.equal(now.panels.find(p => p.id === id).on, false, "and this tab's edit is in")
})

test("Reset Everything puts the zap-button and logo settings back too", async () => {
  const { isAppKey } = await import("../src/net/reset-all.js")
  assert.ok(isAppKey("postButtons"))
  assert.ok(isAppKey("hideNostrVaultBadge"))
  assert.ok(!isAppKey("unrelated"))
})
