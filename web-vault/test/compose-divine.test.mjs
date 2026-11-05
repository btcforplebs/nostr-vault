// New diVine (parity #17): the iPhone's DivineComposeView tags and limit (screens/compose/divine.js), where it goes,
// diVine's relay refusing it, and that it signs and sends a kind 34236. Throwaway keys and a stubbed pool: nothing is
// published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { publishKind } from "../src/net/sync.js"
import { DIVINE_RELAY, LIMIT_SECONDS, RECORD_LIMIT_S, REEL_KIND, clipProblem, divineAnswer, divineRefused, divineRelays, divineTags, lengthShare, lengthText } from "../src/screens/compose/divine.js"
import { parseReel } from "../src/readers/reels.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { composeType, composeHref, COMPOSE_TYPES } = await import("../src/screens/compose/ComposeKinds.jsx")
await import("../src/screens/ComposeScreen.jsx") // the dispatcher, with New diVine, still loads in node

const video = { url: "https://blossom.example/abc.mp4", sha256: "ab".repeat(32), size: 123456, mime: "video/mp4" }
const clip = { width: 1080, height: 1920, duration: 5.6 }

test("the limit: 6.3 s, said as 6; the meter's words", () => {
  assert.equal(RECORD_LIMIT_S, 6.3); assert.equal(LIMIT_SECONDS, 6)
  assert.equal(lengthText(4.24), "4.2s of 6s")
  assert.equal(lengthShare(3), 0.5); assert.equal(lengthShare(6.3), 1)
})

test("clipProblem: a playable type within 6.3 s; a longer one is turned away with why (a browser can't trim)", () => {
  assert.equal(clipProblem({ mime: "video/mp4", duration: 6.3 }), null)
  assert.equal(clipProblem({ mime: "video/quicktime", duration: 2 }), null)
  assert.equal(clipProblem({ mime: "video/webm", duration: 1 }), null)
  assert.equal(clipProblem({ mime: "video/mp4", duration: 9.04 }), "That video is 9.0 seconds. diVines are up to 6 seconds: trim it first, or record one.")
  assert.match(clipProblem({ mime: "video/x-msvideo", duration: 3 }), /isn't a video diVine can play/)
  assert.match(clipProblem({ mime: "video/mp4", duration: NaN }), /length/)
})

test("divineTags: d = the video's hash, imeta in diVine's order, title, published_at, duration, alt, #tags", () => {
  const tags = divineTags({ video, poster: "https://blossom.example/p.jpg", clip, title: "Sunset #Loop", caption: "by the #sea", publishedAt: 1762300000 })
  assert.deepEqual(tags, [
    ["d", video.sha256],
    ["imeta", `url ${video.url}`, "m video/mp4", "image https://blossom.example/p.jpg", "dim 1080x1920", `x ${video.sha256}`, "size 123456"],
    ["title", "Sunset #Loop"], ["published_at", "1762300000"], ["duration", "6"], ["alt", "Sunset #Loop"], ["t", "loop"], ["t", "sea"],
  ])
  const bare = divineTags({ video: { ...video, mime: "" }, poster: "https://p/x.jpg", clip: { ...clip, duration: 0.3 }, title: "", caption: "", publishedAt: 1 })
  assert.equal(bare.some(t => t[0] === "title"), false)
  assert.deepEqual(bare.find(t => t[0] === "duration"), ["duration", "1"])
  assert.deepEqual(bare.find(t => t[0] === "alt"), ["alt", "Short video"])
  assert.ok(bare[1].includes("m video/mp4"))
  assert.equal(divineTags({ video, poster: "p", clip, title: "", caption: "x".repeat(200), publishedAt: 1 }).find(t => t[0] === "alt")[1].length, 140)
})

test("where it goes: the write relays plus diVine's once; diVine refusing it is said, not hidden", () => {
  assert.deepEqual(divineRelays(["wss://w.example/", DIVINE_RELAY + "/"]), ["wss://w.example", DIVINE_RELAY])
  const relays = [{ url: "wss://w.example", ok: true }, { url: DIVINE_RELAY, ok: false, message: "blocked: not allowed" }]
  assert.equal(divineAnswer(relays).ok, false)
  assert.equal(divineRefused(divineAnswer(relays).message), "Posted to your relays, but diVine's relay didn't take it: blocked: not allowed")
  assert.equal(divineRefused(""), "Posted to your relays, but diVine's relay didn't take it: no reason given")
  assert.equal(divineAnswer([{ url: "wss://w.example", ok: true }]), null)
})

test("New diVine opens from #/compose?type=divine and isn't one of New Post's tabs", () => {
  assert.equal(composeType("#/compose?type=divine"), "divine")
  assert.equal(composeHref("divine"), "#/compose?type=divine")
  assert.equal(COMPOSE_TYPES.some(([t]) => t === "divine"), false)
})

test("publishKind signs a kind 34236, stores it, sends it to diVine's relay too, and the feed reads it back", async t => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const stored = [], sent = []
  const vault = { outbox: { event: async e => { stored.push(e); return { ok: true } } } }
  t.mock.method(pool, "publish", (urls, ev) => { sent.push({ urls, ev }); return urls.map(() => Promise.resolve("")) })
  const tags = divineTags({ video, poster: "https://blossom.example/p.jpg", clip, title: "", caption: "hi", publishedAt: 5 })
  const res = await publishKind(vault, { signEvent: async tpl => finalizeEvent(tpl, sk) }, pk, REEL_KIND, "hi", divineRelays(["wss://w.example"]), tags)
  assert.equal(res.event.kind, 34236)
  assert.ok(verifyEvent(res.event))
  assert.deepEqual(stored.map(e => e.id), [res.event.id])
  assert.ok(sent[0].urls.includes(DIVINE_RELAY) && sent[0].urls.includes("wss://w.example"))
  assert.equal(divineAnswer(res.relays).ok, true)
  const r = parseReel(res.event)
  assert.equal(r.video, video.url); assert.equal(r.poster, "https://blossom.example/p.jpg"); assert.equal(r.caption, "hi")
})
