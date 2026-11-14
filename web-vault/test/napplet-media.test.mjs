// Plan P5: the Media napplet (its pure block, run as shipped) and the shell's NAP-BLOSSOM rules (blossom-dispatch.js):
// only the user's own servers and own files, the private-data grant for outside napplets, a delete always asked
// (once per file for a minute), a vault's copy kept, and no Blossom auth ever reaching a napplet.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import { blossomHandler, DELETE_YES_MS } from "../src/napplet/blossom-dispatch.js"
import { createHandlers } from "../src/napplet/dispatch.js"
import { defaultGrant } from "../src/napplet/policy.js"
import { SHELL_DOMAINS } from "../src/napplet/manifest.js"
import { askWords, domainWord } from "../src/napplet/consent-words.js"

const html = fs.readFileSync(new URL("../napplets/media/index.html", import.meta.url), "utf8")
const box = {}
vm.runInNewContext(`${html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))}\n;Object.assign(box, { kindOf, mergeLists, sections, missingFrom, summary, FILTERS, formatBytes, galleryStats, health, withNoteTiles, rangesOf, CHUNK })`, { box, Date, URL })
const plain = x => JSON.parse(JSON.stringify(x))
const H = c => c.repeat(64), ME = H("a"), OTHER = H("b")
const S1 = "https://one.example", S2 = "https://two.example"

test("media: lists merged by hash with the servers that hold each, newest first; junk rows dropped", () => {
  const rows = plain(box.mergeLists([
    { server: S1, blobs: [{ sha256: H("1"), url: `${S1}/${H("1")}.jpg`, type: "image/jpeg", size: 10, uploaded: 5 }, { sha256: "nope", url: "x" }, { sha256: H("3"), url: "javascript:alert(1)" }] },
    { server: S2, blobs: [{ sha256: H("1"), url: `${S2}/${H("1")}.jpg`, uploaded: 5 }, { sha256: H("2"), url: `${S2}/${H("2")}.mp4`, uploaded: 9 }] },
  ]))
  assert.deepEqual(rows.map(r => [r.sha256[0], r.kind, r.servers.length]), [["2", "video", 1], ["1", "photo", 2]])
})

test("media: kinds from type or extension; filters; type sort ranks photo, gif, video, audio", () => {
  assert.deepEqual(["image/gif", "image/png", "video/mp4", "audio/mpeg", "application/pdf"].map(type => box.kindOf({ type })), ["gif", "photo", "video", "audio", "other"])
  assert.equal(box.kindOf({ url: "https://x/a.webm" }), "video")
  const bs = [{ kind: "video", uploaded: 3 }, { kind: "photo", uploaded: 1 }, { kind: "gif", uploaded: 2 }, { kind: "audio", uploaded: 4 }]
  assert.deepEqual(plain(box.sections(bs, "type")[0].blobs.map(b => b.kind)), ["photo", "gif", "video", "audio"])
  assert.equal(bs.filter(box.FILTERS.videos).length, 1)
  const now = new Date(2026, 10, 14, 12).getTime(), day = 86400
  const s = plain(box.sections([{ kind: "photo", uploaded: now / 1000 }, { kind: "photo", uploaded: now / 1000 - day }, { kind: "photo", uploaded: now / 1000 - 1 }], "newest", now))
  assert.deepEqual(s.map(x => [x.day, x.blobs.length]), [["Today", 2], ["Yesterday", 1]])
})

test("media: missing servers and the per-server summary", () => {
  assert.deepEqual(plain(box.missingFrom({ servers: [S1] }, [S1, S2])), [S2])
  assert.equal(box.summary([{ server: S1, ok: true }, { server: S2, ok: false, error: "HTTP 401" }], "Deleted"), "Deleted on 1 of 2 servers. two.example: HTTP 401")
})

function rig({ grant = defaultGrant({ firstParty: true }), yes = true } = {}) {
  const calls = { list: [], mirror: [], remove: [], asks: [] }
  let t = 1000
  const deps = {
    pubkey: ME,
    servers: async () => [S1, S2],
    list: async (server, pk) => { calls.list.push([server, pk]); return { blobs: [{ sha256: H("1"), url: `${server}/${H("1")}`, size: 1, type: "image/png", uploaded: 2, server, nip94: "x" }], status: { [server]: "ok" } } },
    mirror: async (blob, server) => { calls.mirror.push([blob, server]); return [{ server, ok: true }] },
    remove: async (blob, server) => { calls.remove.push([blob, server]); return [{ server, ok: true }] },
    ask: async q => { calls.asks.push(q.what); return yes },
    now: () => t,
  }
  const h = blossomHandler({ grant, who: { title: "Media" }, deps })
  const send = (type, request) => h({ type, id: "1", request })
  return { h, send, calls, tick: ms => { t += ms } }
}

test("blossom: lists only your own servers and your own pubkey; descriptors only", async () => {
  const { send, calls } = rig()
  assert.deepEqual((await send("blossom.servers")).result.servers, [S1, S2])
  const ok = await send("blossom.list", { server: `${S1}/`, pubkey: ME })
  assert.equal(ok.result.ok, true)
  assert.deepEqual(Object.keys(ok.result.blobs[0]).sort(), ["sha256", "size", "type", "uploaded", "url"])
  assert.match((await send("blossom.list", { server: "https://evil.example", pubkey: ME })).error, /not one of your media servers/)
  assert.match((await send("blossom.list", { server: S1, pubkey: OTHER })).error, /only your own files/)
  assert.equal(calls.list.length, 1)
})

test("blossom: the whole domain refuses outside napplets (servers, list, mirror, delete), even with every grant", async () => {
  const outside = rig({ grant: { ...defaultGrant({ domains: ["blossom"] }), privateData: true } })
  for (const [t, req] of [["blossom.servers"], ["blossom.list", { server: S1, pubkey: ME }], ["blossom.mirror", { server: S1, url: "https://x.example/f", sha256: H("1") }], ["blossom.delete", { server: S1, sha256: H("1") }]])
    assert.match((await outside.send(t, req)).error, /private/)
  assert.deepEqual([outside.calls.asks, outside.calls.mirror, outside.calls.remove], [[], [], []])
  const ours = rig()
  await ours.send("blossom.mirror", { server: S1, url: "https://x.example/f", sha256: H("1") })
  assert.deepEqual(ours.calls.asks, [])
  assert.match((await ours.send("blossom.mirror", { server: S1, url: "http://x.example/f", sha256: H("1") })).error, /https url/)
})

test("blossom: a delete is asked even for our own napplet, once per file for a minute; no means nothing is sent", async () => {
  const r = rig()
  await r.send("blossom.delete", { server: S1, sha256: H("1") })
  await r.send("blossom.delete", { server: S2, sha256: H("1") })
  assert.deepEqual(r.calls.asks, ["blossom-delete"])
  assert.equal(r.calls.remove.length, 2)
  assert.equal(r.calls.remove[0][0].url, `${S1}/${H("1")}`) // the shell builds the target; the napplet names only server + hash
  await r.send("blossom.delete", { server: S1, sha256: H("2") })
  r.tick(DELETE_YES_MS + 1)
  await r.send("blossom.delete", { server: S1, sha256: H("1") })
  assert.equal(r.calls.asks.length, 3)
  const no = rig({ yes: false })
  const res = await no.send("blossom.delete", { server: S1, sha256: H("1") })
  assert.deepEqual([res.result.ok, res.result.status, no.calls.remove.length], [false, 403, 0])
  assert.match((await r.send("blossom.delete", { server: "https://evil.example", sha256: H("1") })).error, /not one of your media servers/)
})

test("blossom: your own vault keeps its copy; get/upload/server edits are unsupported here", async () => {
  const r = rig()
  r.calls.remove = []
  const h = blossomHandler({ grant: defaultGrant({ firstParty: true }), who: {}, deps: { ...{ pubkey: ME, servers: async () => [S1], ask: async () => true, now: () => 0 }, remove: async () => [{ server: S1, ok: false, kept: true }] } })
  const kept = await h({ type: "blossom.delete", id: "1", request: { server: S1, sha256: H("1") } })
  assert.deepEqual([kept.result.ok, kept.result.status], [false, 409])
  for (const t of ["blossom.get", "blossom.upload", "blossom.addServer", "blossom.removeServer"]) assert.equal((await r.send(t, {})).error, "unsupported")
})

test("blossom: the delete sheet is told what the file is (url, size, type) from the shell's own look, and still asks if the look fails", async () => {
  const seen = []
  for (const describe of [async () => ({ size: 9, type: "image/png" }), async () => { throw new Error("down") }]) {
    const h = blossomHandler({ grant: defaultGrant({ firstParty: true }), who: {}, deps: { pubkey: ME, servers: async () => [S1], now: () => 0, describe, ask: async q => { seen.push(q.detail); return false }, remove: async () => assert.fail("sent") } })
    assert.equal((await h({ type: "blossom.delete", id: "1", request: { server: S1, sha256: H("1") } })).result.status, 403)
  }
  assert.deepEqual(seen.map(d => [d.url, d.server, d.size, d.type]), [[`${S1}/${H("1")}`, S1, 9, "image/png"], [`${S1}/${H("1")}`, S1, undefined, undefined]])
})

test("blossom is a shell domain only when the shell wires it, with words for the consent and ask sheets", async () => {
  assert.ok(SHELL_DOMAINS.includes("blossom"))
  assert.match(domainWord("blossom"), /media servers/)
  assert.match(askWords("blossom-delete", { title: "Media" }, { sha256: H("1") }).title, /Media wants to delete a file/)
  const w = askWords("blossom-delete", { title: "Media" }, { sha256: H("1"), server: S1, url: `${S1}/${H("1")}`, size: 2_400_000, type: "image/jpeg" })
  assert.equal(w.image, `${S1}/${H("1")}`) // the sheet shows the picture, not only its hash
  assert.match(w.title, new RegExp(new URL(S1).host))
  assert.match(w.body, /image\/jpeg · 2\.4 MB/)
  assert.equal(askWords("blossom-delete", {}, { sha256: H("1"), server: S1, url: `${S1}/${H("1")}`, type: "video/mp4" }).image, null)
  const { handlers } = createHandlers({ ident: { publisher: "p", dTag: "d", hash: H("c"), title: "t" }, grant: defaultGrant({ firstParty: true }), domains: ["blossom"], deps: { bus: {} } })
  assert.equal((await handlers.blossom({ type: "blossom.list", id: "9" })).error, "unsupported")
})

test("no Blossom auth crosses to a napplet: the handler file never signs, the shell's gallery code does", () => {
  const src = fs.readFileSync(new URL("../src/napplet/blossom-dispatch.js", import.meta.url), "utf8").split("\n").filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l)).join("\n")
  assert.doesNotMatch(src, /signEvent|24242|Authorization/)
})

test("the Reader plays a note's video from shell bytes on a tap, and the Vault's Media swaps only with the switch on", () => {
  const reader = fs.readFileSync(new URL("../napplets/reader/index.html", import.meta.url), "utf8")
  assert.match(reader, /function videoSlot\(url\)[\s\S]*n\.resource\.bytes\(url\)/)
  const vault = fs.readFileSync(new URL("../src/screens/VaultScreen.jsx", import.meta.url), "utf8")
  assert.match(vault, /nappletsOn\(\) \? <MediaPane ctx=\{ctx\} filter=\{filter\} \/> : <BlossomGallery/)
})

test("media: the stats panel is the classic one (sizes, Backed Up unknown while a server is silent, health words)", () => {
  assert.deepEqual([0, 512, 1500, 1_234_567, 2_000_000_000].map(box.formatBytes), ["Zero KB", "512 bytes", "2 KB", "1.2 MB", "2 GB"])
  const A = "https://a.example", B = "https://b.example"
  const files = [{ size: 10, servers: [A, B] }, { size: 5, servers: [A] }]
  assert.deepEqual(plain(box.galleryStats(files, [A, B], { [A]: "ok", [B]: "ok" })), { totalFiles: 2, size: 15, mirrors: 2, answering: 2, backedUp: 1, percent: 50 })
  assert.equal(box.galleryStats(files, [A, B], { [A]: "ok" }).percent, null)
  assert.deepEqual([box.health("ok"), box.health(undefined, true), box.health(undefined), box.health("didn't answer"), box.health("401 unauthorized")], ["Healthy", "Checking…", "Offline", "Offline", "Refused · 401 unauthorized"])
})

test("media: a paired device's new file shows once as New until a server lists it; saved emoji images stay off Media", () => {
  const S = c => c.repeat(64)
  const files = box.mergeLists([{ server: "https://a.example", blobs: [{ sha256: S("1"), url: "https://a.example/1.jpg", uploaded: 100 }, { sha256: S("e"), url: "https://a.example/e.png", uploaded: 50 }] }])
  const tiles = [{ sha256: S("2"), url: "https://a.example/2.mp4", type: "video/mp4", size: 9, uploaded: 200 }, { sha256: S("1"), url: "https://a.example/1.jpg", uploaded: 100 }, { sha256: "nope", url: "https://x" }, { sha256: S("3"), url: "javascript:1" }]
  const out = plain(box.withNoteTiles(files, tiles, [S("e")]))
  assert.deepEqual(out.map(b => [b.sha256[0], b.kind, !!b.fromNote, b.servers.length]), [["2", "video", true, 0], ["1", "photo", false, 1]])
})

test("media: big files come in 8 MB parts, small ones whole", () => {
  assert.equal(box.rangesOf(box.CHUNK), null)
  assert.equal(box.rangesOf(0), null)
  assert.deepEqual(plain(box.rangesOf(box.CHUNK * 2 + 5)), [{ start: 0, end: box.CHUNK - 1 }, { start: box.CHUNK, end: box.CHUNK * 2 - 1 }, { start: box.CHUNK * 2, end: box.CHUNK * 2 + 4 }])
  const html2 = fs.readFileSync(new URL("../napplets/media/index.html", import.meta.url), "utf8")
  assert.match(html2, /#nv-bytes=\$\{r\.start\}-\$\{r\.end\}/)
  assert.match(html2, /if \(part\.size !== r\.end - r\.start \+ 1\) throw/) // a server that ignored the range is caught
})

test("media pane: Posted in rows carry no tags or signature; live tiles map to the napplet's rows", () => {
  const src = fs.readFileSync(new URL("../src/napplet/MediaPane.jsx", import.meta.url), "utf8")
  // MediaPane.jsx is JSX (not loadable in node): its shapes are checked in its source.
  assert.match(src, /return \{ id: ev\.id, pubkey: ev\.pubkey, createdAt: ev\.created_at, name: [^\n]*, preview: notePreview\(ev\.content\)\.slice\(0, 160\) \}/)
  assert.match(src, /export const tileRows = tiles => tiles\.filter\(t => t\?\.urls\?\.length\)\.map\(t => \(\{ sha256: t\.sha256, url: t\.urls\[0\], type: t\.mime, size: t\.size, uploaded: t\.createdAt \}\)\)/)
  assert.match(src, /actions: \{ media: \["open", "notes", "tiles"\] \}/)
  assert.match(src, /archetype: "note", actions: \["open"\][\s\S]*location\.hash = `#\/thread\/\$\{p\.id\}`/)
})

test("media: a video streams from the napplet origin's worker when it controls the page, else comes whole in parts", () => {
  const html2 = fs.readFileSync(new URL("../napplets/media/index.html", import.meta.url), "utf8")
  assert.match(html2, /if \(!navigator\.serviceWorker\?\.controller \|\| !\(b\.size > 0\) \|\| !n\.resource\) return null/)
  assert.match(html2, /return new URL\(`nv-stream\/\$\{id\}`, location\.href\)\.href/)
  assert.match(html2, /n\.resource\.bytes\(`\$\{s\.url\}#nv-bytes=\$\{d\.start\}-\$\{end\}`\)/)
  assert.match(html2, /if \(part\.size !== end - d\.start \+ 1\) throw/)
  assert.match(html2, /function hide\(\) \{\n  streams\.clear\(\)/)
})
