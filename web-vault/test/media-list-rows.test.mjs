// Vault › Media W1: a list view beside the grid (thumbnail, type, size, date, N/M servers), a Grid/List toggle kept in
// nv-gallery-layout, and the Largest/Smallest sorts (RESEARCH/NV_MEDIA_LIST_SIZE_2026_11_26.md §3 item 4).
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
const { sections, loadLayout, saveLayout, SORTS, loadSort } = await import("../src/screens/BlossomGallery.jsx")
const { MediaListRows, sizeLabel, typeLabel, dateLabel, serversLabel, detailLine } = await import("../src/screens/MediaListRows.jsx")

const S = ["https://a.example", "https://b.example", "https://c.example"]
const b = (id, kind, size, uploaded = 1000, extra = {}) => ({ sha256: id, kind, size, uploaded, type: "", servers: S.slice(0, 2), ...extra })
const ids = secs => secs.flatMap(s => s.blobs.map(x => x.sha256))

test("Largest/Smallest: one undated run by size, files with no size last, equal sizes newest first", () => {
  const files = [b("small", "photo", 10), b("big", "video", 9000), b("none", "photo", undefined), b("mid-old", "photo", 500, 100), b("mid-new", "photo", 500, 200)]
  const big = sections(files, "largest", "en-US")
  assert.equal(big.length, 1); assert.equal(big[0].day, "")
  assert.deepEqual(ids(big), ["big", "mid-new", "mid-old", "small", "none"])
  assert.deepEqual(ids(sections(files, "smallest", "en-US")), ["small", "mid-new", "mid-old", "big", "none"])
  assert.deepEqual(sections([], "largest"), [])
  const m = new Map([["nv-gallery-sort", "smallest"]])
  assert.equal(loadSort({ getItem: k => m.get(k) ?? null }), "smallest")
  assert.ok(SORTS.some(s => s.id === "largest"))
})

test("the layout is kept in nv-gallery-layout; grid when unset or unknown", () => {
  const m = new Map(), st = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) }
  assert.equal(loadLayout(st), "grid")
  saveLayout("list", st); assert.equal(m.get("nv-gallery-layout"), "list"); assert.equal(loadLayout(st), "list")
  m.set("nv-gallery-layout", "mosaic"); assert.equal(loadLayout(st), "grid")
})

test("row labels: type, size, date and N/M servers", () => {
  assert.deepEqual([sizeLabel(512), sizeLabel(850_000), sizeLabel(2_516_582), sizeLabel(3 * 1073741824), sizeLabel(undefined), sizeLabel(0)],
    ["512 B", "830 KB", "2.4 MB", "3.00 GB", "", ""])
  assert.deepEqual([typeLabel({ kind: "photo" }), typeLabel({ kind: "gif" }), typeLabel({ kind: "video" }), typeLabel({ kind: "other", type: "audio/mpeg" }),
    typeLabel({ kind: "other", type: "application/pdf" }), typeLabel({ kind: "other" })], ["Photo", "GIF", "Video", "Audio", "application/pdf", "File"])
  assert.equal(dateLabel(Date.UTC(2026, 10, 3, 12) / 1000, "en-GB"), "3 Nov 2026")
  assert.equal(dateLabel(undefined), "")
  assert.equal(serversLabel(b("x", "photo", 1), S), "2/3 servers")
  assert.equal(serversLabel(b("x", "photo", 1, 1, { fromNote: true }), S), "New")
  assert.equal(serversLabel(b("x", "photo", 1), []), "")
  assert.equal(detailLine(b("v", "video", 2_516_582, Date.UTC(2026, 10, 3, 12) / 1000), "en-GB"), "Video · 2.4 MB · 3 Nov 2026")
  assert.equal(detailLine(b("p", "photo", undefined, 0), "en-GB"), "Photo")
})

test("MediaListRows draws one row per file with the grid's thumbnail, and a tap opens that file", () => {
  const opened = []
  const files = [b("one", "photo", 2048), b("two", "video", 4096)]
  const tree = MediaListRows({ blobs: files, servers: S, thumb: x => `thumb:${x.sha256}`, onOpen: id => opened.push(id), locale: "en-GB" })
  const rows = tree.props.children
  assert.equal(rows.length, 2)
  const text = JSON.stringify(rows[0])
  assert.match(text, /thumb:one/); assert.match(text, /Photo · 2 KB/); assert.match(text, /2\/3 servers/)
  rows[1].props.onClick()
  assert.deepEqual(opened, ["two"])
})

test("the gallery offers the Grid/List toggle and draws MediaListRows in list layout, the mosaic otherwise", () => {
  const src = readFileSync(new URL("../src/screens/BlossomGallery.jsx", import.meta.url), "utf8")
  assert.match(src, /layout === "list" \? <MediaListRows blobs=\{g\.blobs\} servers=\{servers\} thumb=\{b => <Thumb blob=\{b\} \/>\} onOpen=\{setOpen\} \/> : <Mosaic/)
  assert.match(src, /onClick=\{\(\) => \{ setLayout\(l\); saveLayout\(l\) \}\}/)
})
