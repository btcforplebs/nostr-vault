// The box's jobs in the Vault Dashboard (One Vault W4) over a mock box: Still to bring in runs and cancels on the box,
// Backups on your box makes and restores backups, Restart box sits in the status card's menu for the first account,
// Rebuild now asks the box, and the box's block list follows the first account's blocks. Rendered through Vite's SSR
// loader into a small fake DOM. Nothing is sent anywhere.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"

// Just enough DOM for preact to render into and for the test to read text back.
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
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
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { (this.on ??= {})[type] = fn } // kept, so a test can click
  removeEventListener() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}
globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}

globalThis.confirm = () => true
const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { useBoxImports, useBoxTrust, useBoxBlocklistSync, useBoxFirst, boxJobsFile } = await vite.ssrLoadModule("/src/box/useBoxJobs.js")
const { BoxStillToBringIn } = await vite.ssrLoadModule("/src/box/BoxStillToBringIn.jsx")
const { BoxBackupSection, jobText } = await vite.ssrLoadModule("/src/box/BoxBackupSection.jsx")
const { StatusCard } = await vite.ssrLoadModule("/src/components/dashboard/StatusCard.jsx")
const { boxApi } = await vite.ssrLoadModule("/src/box/api.js")
const { mockBox } = await vite.ssrLoadModule("/src/box/mock.js")
test.after(() => vite.close())
const sk = generateSecretKey()
const signer = { signEvent: async t => finalizeEvent(t, sk) }
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const all = (n, out = []) => { if (n.nodeType === 1) out.push(n); n.childNodes.forEach(c => all(c, out)); return out }
// preact's listener reads the event's type and runs on the element.
const fire = (n, name, extra = {}) => {
  // This DOM has no onclick property, so preact listens under "Click" rather than "click".
  const type = Object.keys(n.on ?? {}).find(k => k.toLowerCase() === name)
  if (!type) throw new Error(`no ${name} listener on ${n.localName}`)
  return n.on[type].call(n, { type, currentTarget: n, target: n, preventDefault() {}, stopPropagation() {}, ...extra })
}
const button = (el, label) => all(el).find(n => n.localName === "button" && n.textContent === label)

const mounted = new Set()
test.afterEach(() => { for (const el of mounted) render(null, el); mounted.clear() })
const api = (fetchImpl = mockBox()) => boxApi({ signer, base: "http://box.test/api/box", fetchImpl })
async function mount(vnode, until = /Asking your box/) {
  const el = document.createElement("div")
  mounted.add(el)
  render(vnode, el)
  for (let i = 0; i < 50 && (until.test(el.textContent) || !el.textContent); i++) await tick(5)
  return el
}
// A spy on what the page asked the box: [method name].
const spy = (inner = mockBox()) => { const seen = []; const f = async (url, init = {}) => { seen.push(`${init.method ?? "GET"} ${new URL(url).pathname.replace("/api/box/", "")}`); return inner(url, init) }; f.seen = seen; return f }

function Imports({ api }) { return h(BoxStillToBringIn, { imports: useBoxImports(api) }) }

test("Still to bring in reads the box's jobs and runs one on the box; a busy box says so", async () => {
  const f = spy()
  const el = await mount(h(Imports, { api: api(f) }), /^$/)
  for (let i = 0; i < 50 && !/relay\.example/.test(el.textContent); i++) await tick(5)
  assert.match(el.textContent, /relay\.example/, "the box's unread range shows")
  fire(button(el, "Run"), "click") // the first never-run long job
  for (let i = 0; i < 50 && !button(el, "Cancel"); i++) await tick(5)
  assert.ok(f.seen.includes("POST imports/run"), f.seen.join(","))
  assert.ok(button(el, "Cancel"), "the running job offers Cancel")
  fire(button(el, "Cancel"), "click"); await tick(30)
  assert.ok(f.seen.includes("POST imports/cancel"))
})

test("boxJobsFile fills every job in order, as the browser's file does", () => {
  const f = boxJobsFile({ jobs: [{ name: "replies", status: "running" }] })
  assert.deepEqual(f.jobs.map(j => j.name), ["setup", "replies", "older_relays", "wider_network", "list_history"])
  assert.equal(f.jobs[1].status, "running")
  assert.equal(f.jobs[0].status, "never")
  assert.equal(boxJobsFile(null).jobs.length, 5)
})

test("Backups on your box: Back up now adds one, Restore asks first and says what happened", async () => {
  const f = spy()
  let asked = ""
  const el = await mount(h(BoxBackupSection, { api: api(f), confirmFn: q => { asked = q; return true } }))
  assert.match(el.textContent, /1 kept/)
  fire(button(el, "Back up"), "click")
  for (let i = 0; i < 400 && !/Backed up at/.test(el.textContent); i++) await tick(10)
  assert.match(el.textContent, /Backed up at/)
  assert.match(el.textContent, /2 kept/)
  fire(all(el).filter(n => n.localName === "button" && n.textContent === "Restore")[1], "click")
  assert.match(asked, /adds its notes to the vault \(nothing is deleted\)/)
  for (let i = 0; i < 400 && !/Restored vault-20261120-030000\.zip/.test(el.textContent); i++) await tick(10)
  assert.match(el.textContent, /Restored vault-20261120-030000\.zip/)
  assert.ok(f.seen.includes("POST backups/restore"))
})

test("a declined restore sends nothing; a refused section says why", async () => {
  const f = spy()
  const el = await mount(h(BoxBackupSection, { api: api(f), confirmFn: () => false }))
  fire(all(el).find(n => n.localName === "button" && n.textContent === "Restore"), "click"); await tick(20)
  assert.ok(!f.seen.includes("POST backups/restore"))
  const refused = await mount(h(BoxBackupSection, { api: api(async () => new Response("{}", { status: 403 })) }))
  assert.match(refused.textContent, /Only the box's owner can do this/)
})

test("job lines: where it is, and how it ended", () => {
  assert.equal(jobText({ kind: "backup", phase: "stopping" }), "Backup: Stopping the vault…")
  assert.equal(jobText({ kind: "restore", phase: "failed", error: "nothing in this backup could be restored" }), "Restore failed: nothing in this backup could be restored")
  assert.equal(jobText(null), "")
})

test("Restart box is in the box card's menu only when given (the first account)", async () => {
  const status = { value: { uptime: 60, version: "1" } }
  const none = await mount(h(StatusCard, { box: { status, connections: {} } }), /^$/)
  assert.ok(!all(none).some(n => n.attributes?.["aria-label"] === "Box controls"))
  let restarted = 0
  const el = await mount(h(StatusCard, { box: { status, connections: {}, onRestart: () => restarted++ } }), /^$/)
  fire(all(el).find(n => n.attributes?.["aria-label"] === "Box controls"), "click"); await tick()
  fire(button(el, "Restart box"), "click"); await tick()
  assert.equal(restarted, 1)
})

function Trust({ api, out }) { const t = useBoxTrust(api); out.t = t; return h("p", null, t.note) }
test("Rebuild now asks the box and says what it answered", async () => {
  const out = {}
  const el = await mount(h(Trust, { api: api(), out }), /^$/)
  await out.t.rebuild(); await tick(10)
  assert.match(el.textContent, /Rebuilding who can reach you\./)
  for (let i = 0; i < 400 && !/Rebuilt/.test(el.textContent); i++) await tick(10) // the next poll: the mock's rebuild is done
  assert.match(el.textContent, /Rebuilt: 5,120 people\./)
})

function Sync({ api, first, blocked, loaded }) { useBoxBlocklistSync(api, { first, blocked, loaded }); return h("p", null, "x") }
test("the box's block list follows the first account's blocks; never for another account or before blocks load", async () => {
  const hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
  for (const props of [{ first: false, loaded: true }, { first: true, loaded: false }]) {
    const f = spy()
    await mount(h(Sync, { api: api(f), blocked: new Set([hex]), ...props }), /^$/); await tick(30)
    assert.deepEqual(f.seen, [], JSON.stringify(props))
  }
  const box = mockBox(), f = spy(box)
  await mount(h(Sync, { api: api(f), first: true, loaded: true, blocked: new Set([hex]) }), /^$/)
  for (let i = 0; i < 50 && !f.seen.includes("POST blocklist"); i++) await tick(10)
  assert.deepEqual(f.seen, ["GET blocklist", "POST blocklist"])
  const again = spy(box) // the box already has it: nothing sent
  await mount(h(Sync, { api: api(again), first: true, loaded: true, blocked: new Set([hex]) }), /^$/); await tick(50)
  assert.deepEqual(again.seen, ["GET blocklist"])
})

test("useBoxFirst: false until the box says first, then follows it", async () => {
  const subs = new Set(), account = { state: undefined, subscribe: f => { subs.add(f); return () => subs.delete(f) } }
  const out = {}
  function F() { out.first = useBoxFirst(account); return h("p", null, String(out.first)) }
  await mount(h(F), /^$/)
  assert.equal(out.first, false)
  for (let i = 0; i < 50 && !subs.size; i++) await tick(5) // the effect subscribes after the first render
  for (const f of subs) f({ state: "first" })
  await tick(10)
  assert.equal(out.first, true)
})
