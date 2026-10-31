// The box screens (src/box/BoxScreen.jsx) over a mock box: every part shows, unknowns read "—", Move vault to… and
// Update say what the box answered. Rendered through Vite's SSR loader into a small fake DOM. Nothing is sent anywhere.
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
const { BoxScreen } = await vite.ssrLoadModule("/src/box/BoxScreen.jsx")
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


async function mount(fetchImpl = mockBox()) {
  const el = document.createElement("div")
  render(h(BoxScreen, { ctx: { signer }, api: boxApi({ signer, base: "http://box.test/api/box", fetchImpl }) }), el)
  for (let i = 0; i < 50 && /Asking the box/.test(el.textContent); i++) await tick(5)
  return el
}

test("status, storage, mesh, My Devices and Update all show from the box", async () => {
  const el = await mount()
  const t = el.textContent
  for (const s of ["Status", "Storage", "Mesh", "My Devices", "Update"]) assert.ok(t.includes(s), s)
  assert.match(t, /for 3d 4h/)
  assert.match(t, /Version 1\.0\.0/)
  assert.match(t, /18\.4 GB of 512 GB/)
  assert.match(t, /\/data/)
  assert.match(t, /Connected/)
  assert.match(t, /Approved/)
  assert.match(t, /add this box as a Home vault/)
  assert.ok(button(el, "Move vault to…"))
  render(null, el)
})

test("Move vault to…: asks for a folder, sends it, says what the box answered", async () => {
  const el = await mount()
  fire(button(el, "Move vault to…"), "click"); await tick()
  const input = all(el).find(n => n.localName === "input"), form = all(el).find(n => n.localName === "form")
  fire(input, "input", { currentTarget: { value: "/mnt/disk/nostr-vault" } }); await tick()
  fire(form, "submit"); await tick(30)
  assert.match(el.textContent, /Moving your vault to \/mnt\/disk\/nostr-vault/)
  render(null, el)
})

test("Update: the box's answer and its rollback note", async () => {
  const el = await mount()
  fire(button(el, "Check for update and install"), "click"); await tick(30)
  assert.match(el.textContent, /Updating 1\.0\.0 to 1\.0\.1\. Version 1\.0\.0 is kept/)
  render(null, el)
})

test("a refused part says why and the others still show; missing numbers read —", async () => {
  const box = mockBox()
  const fetchImpl = async (url, init) => url.endsWith("/devices") ? new Response("{}", { status: 403 })
    : url.endsWith("/status") ? new Response(JSON.stringify({ version: "1.0.0" }), { status: 200 }) : box(url, init)
  const el = await mount(fetchImpl)
  assert.match(el.textContent, /Only the box's owner can do this/)
  assert.match(el.textContent, /Running/)
  assert.match(el.textContent, /— of —/)
  assert.ok(!/ 0 B/.test(el.textContent), "unknown is never 0")
  assert.match(el.textContent, /\/data/, "storage still shows")
  render(null, el)
})
