// Settings › Backup › Export notes on an iPhone Home Screen web app saved nothing: iOS ignores <a download> for a blob
// there, and the card still said "Saved". The export now waits for its own tap (Save backup file), which goes through
// the share sheet on touch devices and the download elsewhere, and "Saved" only comes after it. saveFile is tested on
// its own, then the real BackupCard is rendered with a fake Haven and a fake navigator. Test keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { h, render } from "preact"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { saveFile, prefersShare } from "../src/net/save-file.js"

// Node can't load .jsx: compile it with Vite's Oxc transform, as in poll-vote-publish.test.mjs.
registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

// Just enough DOM for preact, and for saveFile's <a download>: clicks on an anchor are recorded in `downloads`.
const downloads = []
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.on = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes; return s ? s[s.indexOf(this) + 1] ?? null : null }
  insertBefore(n, ref) {
    n.parentNode?.removeChild(n)
    const i = ref ? this.childNodes.indexOf(ref) : -1
    i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n)
    n.parentNode = this
    return n
  }
  appendChild(n) { return this.insertBefore(n, null) }
  append(...ns) { for (const n of ns) this.appendChild(n) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { this.on[type.toLowerCase()] = { type, fn } }
  removeEventListener(type) { delete this.on[type.toLowerCase()] }
  click() {
    if (this.localName === "a") return downloads.push({ href: this.href, download: this.download })
    const { type, fn } = this.on.click; fn.call(this, { type, currentTarget: this, stopPropagation() {}, preventDefault() {} })
  }
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  all(pred) { return [...(pred(this) ? [this] : []), ...this.childNodes.flatMap(c => c.all?.(pred) ?? [])] }
}
globalThis.document = {
  body: new Node(1, "body"),
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const zipBlob = () => new Blob([new Uint8Array([0x50, 0x4b, 3, 4])], { type: "application/zip" })

// A navigator: `touch` points, whether it can share files, and what share() does (resolve, or throw a named error).
function fakeNav({ touch = 5, canShare = true, shareThrows } = {}) {
  const shared = []
  return {
    shared, maxTouchPoints: touch,
    canShare: d => canShare && Array.isArray(d.files),
    share: async d => { if (shareThrows) throw Object.assign(new Error(shareThrows), { name: shareThrows }); shared.push(d.files) },
  }
}

test("a phone shares the file; nothing is downloaded", async () => {
  downloads.length = 0
  const nav = fakeNav()
  assert.equal(await saveFile(zipBlob(), "b.zip", { nav }), "shared")
  assert.equal(nav.shared.length, 1)
  assert.equal(nav.shared[0][0].name, "b.zip")
  assert.equal(nav.shared[0][0].type, "application/zip")
  assert.equal(downloads.length, 0)
})

test("closing the share sheet is 'cancelled', with no download behind it", async () => {
  downloads.length = 0
  assert.equal(await saveFile(zipBlob(), "b.zip", { nav: fakeNav({ shareThrows: "AbortError" }) }), "cancelled")
  assert.equal(downloads.length, 0)
})

test("a share sheet that won't take the file (Android's size cap) falls back to the download", async () => {
  downloads.length = 0
  assert.equal(await saveFile(zipBlob(), "b.zip", { nav: fakeNav({ shareThrows: "NotAllowedError" }) }), "downloaded")
  assert.deepEqual(downloads.map(d => d.download), ["b.zip"])
})

test("a desktop browser downloads, even when it could share; so does one that can't share files", async () => {
  for (const nav of [fakeNav({ touch: 0 }), fakeNav({ canShare: false }), {}]) {
    downloads.length = 0
    assert.equal(await saveFile(zipBlob(), "b.zip", { nav }), "downloaded")
    assert.deepEqual(downloads.map(d => d.download), ["b.zip"])
    assert.equal(nav.shared?.length ?? 0, 0)
  }
  assert.equal(prefersShare({ maxTouchPoints: 5, share() {}, canShare() { throw new TypeError("x") } }, null), false)
})

// ---- the real card ----
const store = new Map()
globalThis.localStorage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k) }
const { BackupCard } = await import("../src/components/BackupCard.jsx")

// A Haven whose every route is empty: each REQ is answered with EOSE straight away.
const enc = new TextEncoder(), dec = new TextDecoder()
const emptyHaven = { conn: () => {
  let onData = () => {}
  return {
    onData: cb => { onData = cb }, onClose() {}, close() {},
    write: b => { const m = JSON.parse(dec.decode(b)); if (m[0] === "REQ") queueMicrotask(() => onData(enc.encode(JSON.stringify(["EOSE", m[1]]) + "\n"))) },
  }
} }

async function card(nav) {
  Object.defineProperty(globalThis, "navigator", { value: nav, configurable: true })
  const root = new Node(1, "div")
  const ctx = { vault: { haven: emptyHaven }, session: { pubkey: getPublicKey(generateSecretKey()) } }
  render(h(BackupCard, { ctx }), root)
  const text = () => root.textContent
  const button = label => root.all(n => n.localName === "button" && n.textContent === label)[0]
  const tap = async label => { button(label).click(); await tick(20) }
  // Export reads every route before it says Ready; on a busy machine that is longer than one tap's wait.
  const until = async (re, ms = 3000) => { for (const t0 = Date.now(); !re.test(text()) && Date.now() - t0 < ms;) await tick(10) }
  return { text, button, tap, until }
}

test("Export only prepares the file: no share, no download, no 'Saved' until Save backup file is tapped", async () => {
  downloads.length = 0
  const nav = fakeNav()
  const c = await card(nav)
  assert.equal(c.button("Save backup file"), undefined)
  await c.tap("Export notes")
  await c.until(/Ready:/)
  assert.match(c.text(), /Ready: your notes 0, private notes 0, messages 0, inbox 0, feed cache 0\. Tap Save backup file/)
  assert.doesNotMatch(c.text(), /Saved/)
  assert.equal(nav.shared.length, 0)
  assert.equal(downloads.length, 0)
  await c.tap("Save backup file")
  assert.equal(nav.shared.length, 1)
  assert.match(nav.shared[0][0].name, /^nostrvault-backup-\d{4}-\d\d-\d\d\.zip$/)
  assert.match(c.text(), /Saved: your notes 0, private notes 0, messages 0, inbox 0, feed cache 0\./)
  assert.equal(c.button("Save backup file"), undefined, "the button goes once the file is saved")
})

test("a closed share sheet says 'Not saved yet' and keeps the button for another try", async () => {
  const nav = fakeNav({ shareThrows: "AbortError" })
  const c = await card(nav)
  await c.tap("Export notes")
  await c.until(/Ready:/)
  await c.tap("Save backup file")
  assert.match(c.text(), /Not saved yet/)
  assert.doesNotMatch(c.text(), /Saved:/)
  assert.ok(c.button("Save backup file"))
})

test("on a desktop the Save backup file tap downloads the zip", async () => {
  downloads.length = 0
  const c = await card(fakeNav({ touch: 0 }))
  await c.tap("Export notes")
  await c.until(/Ready:/)
  assert.equal(downloads.length, 0)
  await c.tap("Save backup file")
  assert.equal(downloads.length, 1)
  assert.match(downloads[0].download, /^nostrvault-backup-.*\.zip$/)
  assert.match(c.text(), /Saved:/)
})
