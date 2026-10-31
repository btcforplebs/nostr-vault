// Vault › Media against the iPhone's gallery: Newest/Oldest/Media type sorts (dated runs only for the date sorts),
// the iPhone's type order, a badge on every tile, its wording, and the Vault's Refresh asking the servers again.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { SORTS, loadSort, sections, typeRank, isAudio, neighbour, rememberedServers } = await import("../src/screens/BlossomGallery.jsx")
const day = (d, h = 12) => Date.UTC(2026, 9, d, h) / 1000
const b = (id, kind, uploaded, type = "") => ({ sha256: id, kind, uploaded, type, servers: [] })
const files = [b("p1", "photo", day(1)), b("v2", "video", day(2)), b("g3", "gif", day(3)), b("a4", "other", day(4), "audio/mpeg"), b("o5", "other", day(5), "application/pdf"), b("p6", "photo", day(6))]
const ids = secs => secs.flatMap(s => s.blobs.map(x => x.sha256))

test("the iPhone's sorts, without 'On relay first' (no relay-held media on the web); newest by default", () => {
  assert.deepEqual(SORTS.map(s => s.label), ["Newest first", "Oldest first", "Media type"])
  const m = new Map(); const st = { getItem: k => m.get(k) ?? null }
  assert.equal(loadSort(st), "newest")
  m.set("nv-gallery-sort", "type"); assert.equal(loadSort(st), "type")
  m.set("nv-gallery-sort", "bogus"); assert.equal(loadSort(st), "newest")
})

test("newest and oldest come in dated runs; media type is one run: photos, GIFs, videos, audio, other, newest first within", () => {
  assert.deepEqual(ids(sections(files, "newest", "en-US")), ["p6", "o5", "a4", "g3", "v2", "p1"])
  assert.deepEqual(ids(sections(files, "oldest", "en-US")), ["p1", "v2", "g3", "a4", "o5", "p6"])
  // The phone's headings, read on Tuesday 6 October: the 4th (Sunday) and 5th are this week.
  const now = new Date(2026, 9, 6, 18)
  assert.deepEqual(sections(files, "newest", "en-US", now).map(s => [s.day, s.blobs.length]), [["Today", 1], ["This Week", 2], ["This Month", 3]])
  assert.deepEqual(sections(files, "oldest", "en-US", now).map(s => s.day), ["This Month", "This Week", "Today"])
  const t = sections(files, "type", "en-US")
  assert.equal(t.length, 1)
  assert.equal(t[0].day, "")
  assert.deepEqual(ids(t), ["p6", "p1", "g3", "v2", "a4", "o5"])
  assert.deepEqual(sections([], "type"), [])
})

test("audio is told apart from other files", () => {
  assert.equal(isAudio(b("x", "other", 0, "audio/ogg")), true)
  assert.equal(isAudio(b("x", "other", 0, "application/pdf")), false)
  assert.equal(typeRank(b("x", "other", 0, "audio/ogg")), 3)
  assert.equal(typeRank(b("x", "other", 0, "")), 4)
})

const src = readFileSync(new URL("../src/screens/BlossomGallery.jsx", import.meta.url), "utf8")
test("every tile shows how many servers hold it; the iPhone's loading and empty wording", () => {
  assert.match(src, /\{servers\.length > 0 && <span class="blossom-badge"/)
  for (const w of ["Loading media…", "No media found", "Try changing your filter settings"]) assert.ok(src.includes(w), w)
  assert.match(src, /found\.blobs\.length > 0 && <p class="muted small">Try changing your filter settings/)
})

test("the Vault's Refresh asks the media servers again", () => {
  const vault = readFileSync(new URL("../src/screens/VaultScreen.jsx", import.meta.url), "utf8")
  assert.match(vault, /onClick=\{\(\) => \{ setRefreshes\(n => n \+ 1\); load\(\{ hold: false \}\) \}\}/)
  assert.match(vault, /<BlossomGallery ctx=\{ctx\} filter=\{filter\} refreshes=\{refreshes\} \/>/)
  assert.match(src, /useEffect\(\(\) => \{ load\(\) \}, \[me, refreshes\]\)/)
})

test("the viewer steps through the grid's order and stops at either end; video tiles carry a play mark", () => {
  const order = [b("x"), b("y"), b("z")]
  assert.equal(neighbour(order, "y", -1), "x")
  assert.equal(neighbour(order, "y", 1), "z")
  assert.equal(neighbour(order, "x", -1), null)
  assert.equal(neighbour(order, "z", 1), null)
  assert.equal(neighbour(order, "gone", 1), null)
  assert.match(src, /ArrowLeft/)
  assert.match(src, /b\.kind === "video" && <span class="blossom-play"/)
})

test("a second visit draws the last list at once; the servers last used are asked while the account's list is looked up", () => {
  assert.match(src, /useState\(\(\) => shown\.get\(me\)\?\.found \?\? null\)/)
  const m = new Map(); const st = { getItem: k => m.get(k) ?? null }
  assert.equal(rememberedServers("pk", st), null)
  m.set("nv-gallery-servers:pk", JSON.stringify(["https://a.example"])); assert.deepEqual(rememberedServers("pk", st), ["https://a.example"])
  m.set("nv-gallery-servers:pk", "[1]"); assert.equal(rememberedServers("pk", st), null)
  m.set("nv-gallery-servers:pk", "nope"); assert.equal(rememberedServers("pk", st), null)
})

test("the delete button says Delete from mirrors, names every server it goes to, and says the home vault keeps its copy", () => {
  const src = readFileSync(new URL("../src/screens/BlossomGallery.jsx", import.meta.url), "utf8")
  assert.match(src, /"Deleting…" : "Delete from mirrors"/)
  assert.doesNotMatch(src, /"Delete everywhere"/)
  assert.match(src, /deleteBlob\(blob, \{ ctx, servers \}\)/)
  assert.match(src, /targets\.map\(hostOf\)\.join/)
  assert.match(src, /home vault \(Nostr Vault on your Mac\) has a copy, it stays: the web can't delete from it/)
})
