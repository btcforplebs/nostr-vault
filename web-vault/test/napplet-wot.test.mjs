// Plan P6: the WoT globe napplet. The shell computes the web (decision 6) and sends a scene (WotPane.jsx sceneOf); the
// napplet draws it with the app's own maths, injected at build (wot-inject.js). These run the napplet's script as it
// ships (maths + its pure block) and check it places people exactly as the classic WoT tab does.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import crypto from "node:crypto"
import { sceneOf } from "../src/napplet/wot-scene.js"
import { injectWot, asScript, MARKER } from "../src/napplet/wot-inject.js"
import { buildWeb, filterWeb, shownByKey, trustPathText, EXTENDED_CAP, FURTHER_CAP } from "../src/net/wot.js"
import { layout, layerFaceCandidates, pictured, LAYER_FACES, RING_FACES } from "../src/net/wot-globe.js"

const read = p => fs.readFileSync(new URL(`../${p}`, import.meta.url), "utf8")
const html = injectWot(read("napplets/wot/index.html"), [read("src/net/wot-pure.js"), read("src/net/wot-globe.js")])
const script = html.slice(html.indexOf("<script>") + 8, html.indexOf("// ---- end pure ----"))
const box = {}
vm.runInNewContext(`${script}\n;Object.assign(box, { webOf, litOf, nodesOf, findPeople, trustPathText, layout })`, { box, TextEncoder, Map, Set })
const plain = x => JSON.parse(JSON.stringify(x))

// A web with ~3 layers: me, 12 follows, people they follow (some by many: vouched, most by few: further out).
const hex = i => crypto.createHash("sha256").update(String(i)).digest("hex")
const ME = "a".repeat(64), F = Array.from({ length: 12 }, (_, i) => hex(1000 + i)), O = Array.from({ length: 60 }, (_, i) => hex(5000 + i * 7919))
const lists = new Map(F.map((f, i) => [f, { pubkey: f, created_at: 1, tags: [...O.filter((_, j) => j % (i + 2) === 0), ...(i % 3 === 0 ? [ME] : []), F[(i + 1) % F.length]].map(p => ["p", p]) }]))
const pictures = new Set([...F.slice(0, 7), ...O.slice(0, 30)])
const profile = pk => (pictures.has(pk) ? { name: `P${pk.slice(-4)}`, picture: `https://pics.example/${pk.slice(-6)}.png` } : { name: `N${pk.slice(-4)}` })


test("inject: the napplet carries the maths once, as plain script", () => {
  assert.equal(html.includes(MARKER), false)
  assert.doesNotMatch(script, /^\s*(import|export)\s/m)
  assert.match(script, /function layout\(web, further/)
  assert.throws(() => asScript("export { a } from './x.js'"), /re-exports/)
  assert.throws(() => injectWot("no marker", []), /exactly one/)
})

test("the napplet places everyone exactly as the classic tab (same nodes, same faces) for every layer and the filter", async () => {
  const built = buildWeb(ME, F, (() => { const m = new Map(); for (const [k, v] of lists) m.set(k, v); return m })(), { extendedMin: 3 })
  const web = filterWeb(built, lists, new Set([O[5]]))
  const scene = plain(sceneOf(web, { profile }))
  // Not a vacuous web: every layer, follow-backs, and faces past the follows.
  assert.ok(web.extended.length >= 3 && web.further.length >= 10 && web.followsMe.size >= 2, `web ${web.extended.length}/${web.further.length}/${web.followsMe.size}`)
  const napWeb = box.webOf(scene)
  const names = scene.profiles
  for (const layer of ["everyone", "following", "close", "furtherOut"]) for (const back of [false, true]) {
    // Classic: WotScreen.jsx's memos for your own globe.
    const lit = back ? web.followsMe : null
    const shown = { extended: shownByKey(web.extended, EXTENDED_CAP), further: shownByKey(web.further, FURTHER_CAP) }
    const gw = { ...web, extended: shown.extended }
    const cand = layerFaceCandidates({ ...web, ...shown }, layer).filter(pk => !lit || lit.has(pk))
    const faces = pictured(cand, pk => pictures.has(pk), LAYER_FACES[layer])
    const n = pk => web.linkers.get(pk)?.length ?? 0
    const ring = [...web.follows].filter(pk => !lit || lit.has(pk)).sort((a, b) => n(b) - n(a))
    const classic = layout(gw, shown.further, faces, new Set(pictured(ring, pk => pictures.has(pk), RING_FACES)))
    const mine = box.nodesOf(napWeb, layer, box.litOf(napWeb, back), pk => !!names[pk]?.[1])
    assert.deepEqual(plain(mine), plain(classic), `${layer} back=${back}`)
    if (layer === "everyone" && !back) assert.ok(classic.filter(x => x.face && x.layer !== "follow" && x.layer !== "me").length >= 5, "outer faces drawn")
  }
  for (const pk of [F[0], O[0], O[59], "b".repeat(64)]) assert.equal(box.trustPathText(napWeb, pk, x => x.slice(0, 4)), trustPathText(web, pk, x => x.slice(0, 4)))
})

test("scene: links as indices into follows, https pictures only, the open card only for a real key", async () => {
  const web = buildWeb(ME, F, lists, { extendedMin: 3 })
  const s = sceneOf(web, { profile: pk => (pk === F[0] ? { name: "Ann", picture: "http://x.example/a.png" } : profile(pk)), open: "zz" })
  assert.equal(s.open, null)
  assert.deepEqual(s.profiles[F[0]], ["Ann", ""])
  const some = Object.entries(s.linkers)[0]
  assert.ok(some[1].every(i => Number.isInteger(i) && F[i]))
  assert.deepEqual(s.counts, { everyone: web.follows.length + web.extended.length + web.further.length, following: web.follows.length, close: web.extended.length, furtherOut: web.further.length })
  assert.equal(sceneOf(web, { profile, open: O[0] }).open, O[0])
})

test("find: by name word or key start, follows first", () => {
  const web = box.webOf({ me: ME, follows: F, extended: [], further: O, linkers: {}, followsMe: [] })
  const names = { [F[2]]: ["Ann Lee"], [O[1]]: ["Lee Ann"] }
  assert.deepEqual(plain(box.findPeople(web, names, "ann")), [F[2], O[1]])
  assert.deepEqual(plain(box.findPeople(web, names, O[3].slice(0, 10))), [O[3]])
  assert.deepEqual(plain(box.findPeople(web, names, "  ")), [])
  assert.deepEqual(plain(box.findPeople(web, names, "Lee An")), [O[1]]) // a whole name with its space
})

test("the WoT tab swaps with the switch on; See their web stays classic; the napplet has no network domain", () => {
  const main = read("main.jsx")
  assert.match(main, /const wotInNapplet = \(hash = location\.hash\) => nappletsOn\(\) && !\/\^#\\\/wot\\\/\[0-9a-f\]\{64\}\\\/web\/\.test\(hash\)/)
  assert.match(main, /wotInNapplet\(\) \? <WotPane/)
  assert.match(read("src/napplet/first-party.js"), /dTag: WOT_DTAG, [^\n]*domains: \["resource", "intent", "theme"\]/)
})

test("every delivery the bus sends passes the shim's own check, the shell's own asks included (no convention given)", async () => {
  const { createBus } = await import("../src/napplet/bus.js")
  const shim = fs.readFileSync(new URL("../node_modules/@napplet/shim/dist/prelude.global.js", import.meta.url), "utf8")
  const start = shim.indexOf("function isIntentDelivery(")
  const src = shim.slice(start, shim.indexOf("\n  }\n", start) + 4)
  const isIntentDelivery = vm.runInNewContext(`(${src})`)
  const sent = []
  const target = { dTag: "nv-wot", send: m => sent.push(m) }
  const bus = createBus()
  bus.register({ id: "nv-wot", title: "WoT", archetype: "wot", actions: ["show"], conventions: [], open: async () => target })
  bus.register({ id: "nv-reader", title: "Reader", archetype: "note", actions: ["open"], conventions: [], open: async () => target })
  const shell = { dTag: "shell", send: () => {} }
  await bus.invoke(shell, { archetype: "wot", action: "show", payload: { me: ME } })
  await bus.invoke(shell, { archetype: "note", action: "open", payload: { id: ME } })
  await bus.invoke(shell, { archetype: "note", action: "open", convention: "napplet:note/open", payload: { id: ME } })
  assert.equal(sent.length, 3)
  for (const m of sent) assert.equal(isIntentDelivery(m.delivery), true, JSON.stringify(m.delivery))
})
