// Napplets P2 (docs/napplets/P2_EMOJI.md): the Emoji napplet and compose's intent to it (emoji-intent.js), and the
// napplet's own origin (origin.js) with the loader headers and the two files a napplet origin serves (csp.js). What
// the browser does with them (navigation cancelled, the service worker, WebRTC) is tools/napplet-leak-check.mjs.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { registerHooks } from "node:module"
import { CATEGORIES, KEYWORDS } from "../src/components/emoji-data.js"
import { pickedEmoji, composeEmoji, emojiTags, EMOJI_TOPIC } from "../src/napplet/emoji-intent.js"
import { createBus } from "../src/napplet/bus.js"
import { nappletOrigin, nappletParentHost } from "../src/napplet/origin.js"
import { isolatedLoaderCsp, nappletOriginFile, loaderCsp, LOADER_FILE, SW_FILE } from "../src/napplet/csp.js"
import { nappletsOn, setNappletsOn } from "../src/napplet/flag.js"

const H = "ab".repeat(32)
const read = p => fs.readFileSync(new URL(p, import.meta.url), "utf8")
const napplet = () => { const n = { dTag: "nv-emoji", sent: [] }; n.send = m => n.sent.push(m); return n }

test("the Emoji napplet carries the same emoji and search words as the app's picker", () => {
  const html = read("../napplets/emoji/index.html")
  const grab = name => JSON.parse(html.match(new RegExp(`const ${name} = (.*)\\n`))[1])
  assert.deepEqual(grab("CATEGORIES"), CATEGORIES)
  assert.deepEqual(grab("KEYWORDS"), KEYWORDS)
  assert.match(html, /inc\.emit\("nv\.emoji\.picked"/)
  assert.ok(!/https?:\/\/(?!\/)/.test(html.replace(/\/\^https:\\\/\\\//g, "")), "the napplet names no network address")
})

test("picks: a plain emoji, or a shortcode with an https picture; anything else is dropped", () => {
  assert.deepEqual(pickedEmoji({ emoji: "🔥" }), { text: "🔥" })
  assert.deepEqual(pickedEmoji({ shortcode: "soapbox", url: "https://cdn.example/s.png" }), { text: ":soapbox:", tag: ["emoji", "soapbox", "https://cdn.example/s.png"] })
  for (const bad of [null, "🔥", { emoji: "" }, { emoji: "x".repeat(17) }, { emoji: "<b>" }, { emoji: "a b" }, { shortcode: "bad code", url: "https://x.example/a.png" },
    { shortcode: "ok", url: "http://x.example/a.png" }, { shortcode: "ok", url: "javascript:alert(1)" }, { shortcode: "ok" }]) assert.equal(pickedEmoji(bad), null, JSON.stringify(bad))
})

test("compose asks by intent; the bus opens the Emoji napplet and delivers; its picks come back on the topic", async () => {
  const bus = createBus(), emoji = napplet(), picks = []
  let opened = 0
  const wire = composeEmoji({ bus, open: async () => { opened++; return emoji }, onPick: p => picks.push(p) })
  const r = await wire.ask()
  assert.deepEqual([r.ok, r.handler, opened], [true, "nv-emoji", 1])
  assert.deepEqual([emoji.sent[0].type, emoji.sent[0].delivery.sender, emoji.sent[0].delivery.archetype, emoji.sent[0].delivery.action], ["intent.deliver", "compose", "emoji", "pick"])
  bus.emit(emoji, EMOJI_TOPIC, { emoji: "🎉" })
  bus.emit(emoji, EMOJI_TOPIC, { shortcode: "x y" }) // dropped
  bus.emit(emoji, "other.topic", { emoji: "🙃" }) // not compose's topic
  assert.deepEqual(picks, [{ text: "🎉" }])
  wire.close()
  bus.emit(emoji, EMOJI_TOPIC, { emoji: "🎈" })
  assert.equal(picks.length, 1)
  assert.equal((await bus.invoke(emoji, { archetype: "emoji", action: "pick" })).ok, false) // handler gone with compose
})

test("a note keeps one emoji tag per custom emoji still in its text", () => {
  const emojis = { soapbox: "https://cdn.example/s.png", gone: "https://cdn.example/g.png", "bad code": "https://x.example/b.png" }
  assert.deepEqual(emojiTags("hi :soapbox: there :soapbox:", emojis), [["emoji", "soapbox", "https://cdn.example/s.png"]])
  assert.deepEqual(emojiTags("nothing", emojis), [])
})

test("each napplet gets its own origin, never the vault's; only on a napplet host or this machine", () => {
  const loc = (hostname, port = "5173", protocol = "http:") => ({ hostname, port, protocol })
  assert.equal(nappletOrigin(H, { loc: loc("localhost"), host: "" }), `http://n-${H.slice(0, 32)}.localhost:5173`)
  assert.equal(nappletOrigin(H, { loc: loc("127.0.0.1", ""), host: "" }), `http://n-${H.slice(0, 32)}.localhost`)
  assert.equal(nappletOrigin(H, { loc: loc("nostrvault.app", "", "https:"), host: "" }), null) // no napplet host: none
  assert.equal(nappletOrigin(H, { loc: loc("nostrvault.app", "", "https:"), host: "nvapps.example" }), `https://n-${H.slice(0, 32)}.nvapps.example`)
  assert.notEqual(nappletOrigin("cd".repeat(32), { loc: loc("localhost"), host: "" }), nappletOrigin(H, { loc: loc("localhost"), host: "" }))
  assert.equal(nappletOrigin("xyz", { loc: loc("localhost"), host: "" }), null)
  assert.equal(nappletParentHost(`n-${H.slice(0, 32)}.localhost:5173`), "localhost:5173")
  for (const h of ["localhost:5173", "n-abc.localhost", `x.n-${H.slice(0, 32)}.localhost`, `n-${H.slice(0, 31)}g.localhost`]) assert.equal(nappletParentHost(h), null, h)
})

test("a napplet origin serves its loader (real origin, guarded, framed by the vault only) and its service worker, nothing else", () => {
  const host = `n-${H.slice(0, 32)}.localhost:5173`, vaultHosts = ["localhost:5173", "127.0.0.1:5173"]
  const loader = nappletOriginFile(`/vault/${LOADER_FILE}`, { host, vaultHosts })
  const csp = loader.headers["Content-Security-Policy"]
  assert.equal(csp, isolatedLoaderCsp({ self: `http://${host}`, vault: "http://localhost:5173 http://127.0.0.1:5173" }))
  assert.match(csp, /connect-src 'none'/)
  assert.match(csp, /frame-ancestors http:\/\/localhost:5173 http:\/\/127\.0\.0\.1:5173;/)
  assert.match(csp, /sandbox allow-scripts allow-same-origin$/)
  assert.match(csp, new RegExp(`worker-src blob: http://${host.replace(/\./g, "\\.")}/vault/${SW_FILE}`))
  assert.ok(!/frame-src|child-src/.test(csp) && /default-src 'none'/.test(csp), "nested frames fall back to default-src 'none'")
  assert.equal(loader.headers["X-DNS-Prefetch-Control"], "off")
  assert.equal(nappletOriginFile(`/vault/${SW_FILE}`, { host, vaultHosts }).file, SW_FILE)
  for (const p of ["/vault/", "/vault/index.html", "/vault/assets/x.js", `/${LOADER_FILE}`, "/vault/sw.js"]) assert.equal(nappletOriginFile(p, { host, vaultHosts }), null, p)
  // The P1 same-origin loader keeps its opaque sandbox.
  assert.match(loaderCsp(), /sandbox allow-scripts$/)
  // vite dev and server.mjs both route napplet hosts through nappletOriginFile.
  for (const f of ["../vite.config.js", "../server.mjs"]) assert.match(read(f), /nappletParentHost\(req\.headers\.host\)[\s\S]*nappletOriginFile\(/, f)
})

test("the loader cancels navigations and reports its guards; the service worker refuses everything but the loader", () => {
  const page = read(`../public/${LOADER_FILE}`)
  assert.match(page, /navigation\.addEventListener\("navigate"/)
  assert.match(page, /e\.preventDefault\(\)/)
  assert.match(page, /nv-loader\.left/)
  assert.match(page, /register\("napplet-sw\.js"\)/)
  assert.match(page, /type: "nv-loader\.ready", guards: g/)
  const sw = read(`../public/${SW_FILE}`)
  assert.match(sw, /respondWith\(Response\.error\(\)\)/)
  assert.match(sw, /clients\.claim\(\)/)
  const host = read("../src/napplet/host.js")
  assert.match(host, /needGuards && !\(g\.nav && g\.sw\)/)
  assert.match(host, /e\.origin !== origin/)
  assert.match(host, /a napplet never runs on the vault's own origin/)
})

// runtime.js pulls in vite's ?raw imports (the shim prelude, napplet files): empty strings here.
registerHooks({ resolve: (spec, ctx, next) => spec.endsWith("?raw") ? { url: "data:text/javascript,export default ''", shortCircuit: true } : next(spec, ctx) })

test("an outside napplet won't open where there is no napplet origin; the user is never asked", async () => {
  const { openNapplet } = await import("../src/napplet/runtime.js")
  let asked = false
  await assert.rejects(openNapplet({ html: "<p>x</p>", loader: "http://localhost/vault/napplet-frame.html", grants: { get: () => null }, consent: async () => { asked = true } }), /can't wall off an outside napplet/)
  assert.equal(asked, false)
})

test("napplets in the app's screens: off until switched on", () => {
  const m = new Map(), store = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: k => m.delete(k) }
  assert.equal(nappletsOn(store), false)
  setNappletsOn(true, store); assert.equal(nappletsOn(store), true)
  setNappletsOn(false, store); assert.equal(nappletsOn(store), false)
})
