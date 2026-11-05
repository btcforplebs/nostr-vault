// The diVines feed (parity #17): the iPhone's Reel / ReelsFeedService rules (readers/reels.js), paging over mock
// relays, its empty states, and that the feed is in the picker, on the rail and on the Dashboard. Throwaway keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { DIVINE_RELAY, EMPTY_PAGES_MAX, REEL_KIND, aspectOf, fetchReelPage, imetaFields, loadScope, mergeReels, nextCursor, parseReel, reelFilter, reelRelays, reelsEmpty, saveScope } from "../src/readers/reels.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

const key = () => { const sk = generateSecretKey(); return { sk, pk: getPublicKey(sk) } }
const [a, b, stranger] = [key(), key(), key()]
const now = 1_762_300_000
let n = 0
const reel = (who, { d = `v${++n}`, url = `https://cdn.example/${n}.mp4`, m = "video/mp4", at = now - n, extra = [], content = "" } = {}) =>
  finalizeEvent({ kind: REEL_KIND, created_at: at, content, tags: [["d", d], ["imeta", `url ${url}`, ...(m ? [`m ${m}`] : []), "image https://cdn.example/p.jpg", "dim 1080x1920"], ...extra] }, who.sk)

test("imeta fields, first value of a repeat kept; dim to aspect", () => {
  assert.deepEqual(imetaFields([["imeta", "url https://x/a.mp4", "m video/mp4", "image https://x/1.jpg", "image https://x/2.jpg", "junk"]]),
    [{ url: "https://x/a.mp4", m: "video/mp4", image: "https://x/1.jpg" }])
  assert.equal(aspectOf("1080x1920"), 0.5625)
  assert.equal(aspectOf("0x10"), null); assert.equal(aspectOf("wide"), null)
})

test("parseReel: the first video in imeta, else a bare url tag; poster, title, caption without the link; warned ones left out", () => {
  const ev = reel(a, { content: "Loop! https://cdn.example/7.mp4", url: "https://cdn.example/7.mp4", extra: [["title", "  Cat  "]] })
  const r = parseReel(ev)
  assert.equal(r.video, "https://cdn.example/7.mp4"); assert.equal(r.mime, "video/mp4"); assert.equal(r.poster, "https://cdn.example/p.jpg")
  assert.equal(r.aspect, 0.5625); assert.equal(r.title, "Cat"); assert.equal(r.caption, "Loop!")
  assert.equal(r.address, `${REEL_KIND}:${a.pk}:${ev.tags[0][1]}`)
  // An image first, then the video: the video is picked.
  const two = finalizeEvent({ kind: REEL_KIND, created_at: now, content: "", tags: [["d", "x"], ["imeta", "url https://x/p.jpg", "m image/jpeg"], ["imeta", "url https://x/v.webm"]] }, a.sk)
  assert.equal(parseReel(two).video, "https://x/v.webm")
  // Older NIP-71: bare url + m tags.
  const old = finalizeEvent({ kind: REEL_KIND, created_at: now, content: "", tags: [["d", "o"], ["url", "https://x/blob"], ["m", "video/mp4"]] }, a.sk)
  assert.equal(parseReel(old).video, "https://x/blob"); assert.equal(parseReel(old).mime, "video/mp4")
  assert.equal(parseReel(reel(a, { extra: [["content-warning", "nsfw"]] })), null)
  assert.equal(parseReel(reel(a, { url: "ftp://x/a.mp4" })), null)
  assert.equal(parseReel({ ...ev, kind: 1 }), null)
})

test("mergeReels: newest first; shown reels keep their place; newer version replaces an unshown one; one reel per video; blocked and untrusted out", () => {
  const r1 = reel(a, { d: "same", at: now - 100 }), r1new = reel(a, { d: "same", at: now - 10 })
  const r2 = reel(b, { at: now - 50 }), dupVideo = reel(b, { url: "https://cdn.example/dup.mp4", at: now - 40 }), dup2 = reel(a, { url: "https://cdn.example/dup.mp4", at: now - 30 })
  const first = mergeReels([], [r1, r2, r1new, dupVideo, dup2, reel(stranger)], { blocked: new Set([stranger.pk]) })
  // The same video twice: the copy that came first stays (ReelsFeedService.seenVideoURLs).
  assert.deepEqual(first.map(r => r.id), [r1new.id, dupVideo.id, r2.id])
  // On screen, an arrival goes after what is shown even when newer, and a newer version of a shown reel waits.
  const shown = first.slice(0, 2)
  const later = reel(b, { at: now }), again = reel(a, { d: "same", at: now - 1 })
  assert.deepEqual(mergeReels(shown, [later, again]).map(r => r.id), [r1new.id, dupVideo.id, later.id])
  // Global: only the web of trust.
  assert.deepEqual(mergeReels([], [reel(a), reel(stranger)], { trust: new Set([a.pk]) }).map(r => r.pubkey), [a.pk])
})

test("filters, relays, cursor", () => {
  assert.deepEqual(reelFilter("following", [a.pk]), { kinds: [34236], limit: 100, authors: [a.pk] })
  assert.equal(reelFilter("following", []), null)
  assert.deepEqual(reelFilter("global", [], 99), { kinds: [34236], limit: 100, until: 99 })
  assert.deepEqual(reelRelays(["wss://relay.divine.video/", "wss://r1.example/", "wss://r1.example"]), [DIVINE_RELAY, "wss://r1.example"])
  assert.equal(nextCursor({ r1: 100, r2: 300 }), 299)
  assert.equal(nextCursor({}), null)
})

test("fetchReelPage over mock relays: each relay asked alone, Global through the web of trust, a dead relay gives nothing", async () => {
  const asked = []
  const events = { [DIVINE_RELAY]: [reel(a, { at: 500 }), reel(stranger, { at: 450 })], "wss://r1.example": [reel(b, { at: 300 })] }
  const query = async (relays, f) => {
    asked.push([relays, f])
    if (relays[0] === "wss://down.example") throw new Error("down")
    return (events[relays[0]] ?? []).filter(e => !f.authors || f.authors.includes(e.pubkey))
  }
  const fol = await fetchReelPage({ scope: "following", me: a.pk, follows: [a.pk, b.pk], readRelays: ["wss://r1.example", "wss://down.example"], query })
  assert.ok(asked.every(([r]) => r.length === 1))
  assert.equal(fol.events.length, 2); assert.equal(fol.cursor, 499); assert.equal(fol.answered, true)
  const glob = await fetchReelPage({ scope: "global", me: a.pk, follows: [b.pk], readRelays: ["wss://r1.example"], query, trustOf: async () => new Set([a.pk, b.pk]) })
  assert.deepEqual([...glob.trust].sort(), [a.pk, b.pk].sort())
  assert.equal(mergeReels([], glob.events, { trust: glob.trust }).length, 2) // the stranger is left out
  const none = await fetchReelPage({ scope: "following", me: a.pk, follows: [], readRelays: [], query })
  assert.equal(none.noFollows, true)
  assert.equal(EMPTY_PAGES_MAX, 4)
})

test("the iPhone's empty diVines", () => {
  assert.deepEqual(reelsEmpty({ scope: "following", noFollows: true }), { title: "You aren't following anyone yet", detail: "Switch to Global to see everyone's videos.", action: "global" })
  assert.equal(reelsEmpty({ scope: "global", failed: true }).title, "Could not reach any relay")
  assert.equal(reelsEmpty({ scope: "following" }).detail, "Nobody you follow has posted a diVine video recently.")
  assert.deepEqual(reelsEmpty({ scope: "global" }), { title: "No videos found", detail: "No diVine videos came back from the relays.", action: "retry" })
})

test("scope is kept per browser, Following by default", () => {
  const store = new Map(), s = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
  assert.equal(loadScope(s), "following")
  saveScope("global", s); assert.equal(loadScope(s), "global")
})

test("diVines is a feed: in the picker with its icon, pinnable on the rail, with a Post a diVine button", async () => {
  globalThis.localStorage ??= { getItem: () => null, setItem: () => {}, removeItem: () => {} }
  const { READERS } = await import("../src/readers/index.js")
  assert.deepEqual(READERS.find(r => r.id === "reels")?.label, "diVines")
  const { FEED_ICON } = await import("../src/components/FeedPickerMenu.jsx")
  assert.ok(FEED_ICON.reels)
  const { webHasFeedPin, NOT_ON_WEB } = await import("../src/desktop/rail/rail-favs.js")
  assert.equal(NOT_ON_WEB.size, 0); assert.equal(webHasFeedPin({ type: "feed", id: "reels" }), true)
  const { PostDivineButton } = await import("../src/readers/ReelsScreen.jsx")
  const btn = PostDivineButton()
  assert.equal(btn.props.href, "#/compose?type=divine"); assert.equal(btn.props["aria-label"], "Post a diVine")
  const { TILE_NAMES } = await import("../src/net/feed-dashboard.js")
  assert.equal(TILE_NAMES.reels, "diVines")
})
