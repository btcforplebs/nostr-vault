// The Vault Dashboard in box mode (One Vault W1) over a mock box: the box's status card, the folded Box screen
// sections (box/BoxFold.jsx), In your vault's numbers, Advanced and the box log; unknowns read "—", Move vault to… and
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
const { useBoxDashboard, boxStorage } = await vite.ssrLoadModule("/src/box/useBoxDashboard.js")
const { BoxStatusDetails, BoxTrustRanking, BoxDevices, BoxStorage, BoxPublic, BoxUpdate } = await vite.ssrLoadModule("/src/box/BoxFold.jsx")
const { BoxLogView } = await vite.ssrLoadModule("/src/box/BoxLogView.jsx")
const { boxActivityItems, lineLevel } = await vite.ssrLoadModule("/src/box/box-activity.js")
const { boxDashboardRedirect } = await vite.ssrLoadModule("/src/box/mode.js")
const { StatusCard } = await vite.ssrLoadModule("/src/components/dashboard/StatusCard.jsx")
const { AdvancedSection } = await vite.ssrLoadModule("/src/components/dashboard/AdvancedSection.jsx")
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


// The dashboard's box-mode pieces, as VaultDashboard.jsx places them, without the browser vault's sections.
function BoxDashboard({ api }) {
  const box = useBoxDashboard({ signer }, { on: true, api })
  const { usage, media } = boxStorage(box.data.contents)
  return h("div", null,
    h(StatusCard, { box: { status: box.data.status, connections: box.data.connections } }),
    h(BoxStatusDetails, { box }), h(BoxTrustRanking, { box }), h(BoxDevices, { box }),
    h("p", null, `usage ${usage ?? "?"} media ${media?.count ?? "?"}`),
    h(BoxStorage, { box }), h(BoxPublic, { ctx: { signer }, box }),
    h(AdvancedSection, { box: box.data.status?.value ?? null }, h(BoxUpdate, { box })),
    h(BoxLogView, { state: box.data.logs }))
}

const mounted = new Set()
// Unmounted after each test even when it failed, so the box poll's timer never keeps node running.
test.afterEach(() => { for (const el of mounted) render(null, el); mounted.clear() })

async function mount(fetchImpl = mockBox()) {
  const el = document.createElement("div")
  mounted.add(el)
  render(h(BoxDashboard, { api: boxApi({ signer, base: "http://box.test/api/box", fetchImpl }) }), el)
  for (let i = 0; i < 50 && /Asking (the|your) box/.test(el.textContent); i++) await tick(5)
  return el
}

test("status, storage, mesh, My Devices and Update all show from the box", async () => {
  const el = await mount()
  const t = el.textContent
  for (const s of ["Status", "Storage", "Mesh", "My Devices", "Update"]) assert.ok(t.includes(s), s)
  assert.match(t, /Your box is running/)
  assert.match(t, /Up 3d 4h · version 1\.0\.0 · 2 connections/)
  assert.ok(!/Closing the tab stops it/.test(t), "no browser-tab wording on a box")
  assert.match(t, /usage 16600000000 media 4210/, "In your vault reads the box's split and media")
  assert.match(t, /blossom: upload failed: disk full/, "the box's own log")
  assert.match(t, /for 3d 4h/)
  assert.match(t, /Version 1\.0\.0/)
  // The box's trust ranking (GET vault-status), with each device by its own name, else its type.
  assert.match(t, /Trust ranking/)
  assert.match(t, /Ranking your web/)
  assert.match(t, /Ring 3 · 411 of 1,980 lists · 37 read this run/)
  assert.match(t, /30,640 people ranked/)
  assert.match(t, /1,840 distant connections at your bar \(55\)/)
  assert.match(t, /LogePhone/)
  assert.match(t, /Took it 3 h ago/)
  assert.match(t, /18\.4 GB of 512 GB/)
  assert.match(t, /\/data/)
  assert.match(t, /Connected/)
  assert.match(t, /Approved/)
  // The box's own paired set decides (P9b): Remove on each device, Add a device below the list.
  assert.match(t, /Devices you pair here reach the box over the mesh/)
  assert.ok(button(el, "Remove"))
  assert.ok(button(el, "Add a device"))
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

test("Update: says updates are manual, never 'started', no rollback promise (audit K2)", async () => {
  const el = await mount()
  fire(button(el, "Check for update and install"), "click"); await tick(30)
  assert.match(el.textContent, /Updates are manual for now\. On the box, install the newer package from https:\/\/github\.com\/btcforplebs\/nostr-vault\/releases/)
  assert.ok(!/Update started|go back to it|goes back/.test(el.textContent), el.textContent)
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

for (const [store, words] of [["startos", "the StartOS Marketplace"], ["umbrel", "the Umbrel App Store"]]) {
  test(`a box ${store} installed: Move is hidden, Update names ${words}`, async () => {
    const el = await mount(mockBox({ store }))
    assert.ok(!button(el, "Move vault to…"), "no Move on a store box")
    assert.match(el.textContent, /app store manages its disk/)
    assert.ok(!button(el, "Check for update and install"), "no update button: the store updates it")
    assert.ok(el.textContent.includes(`Updates come from ${words}: update Nostr Vault there.`), el.textContent)
    assert.ok(!/install the newer package/.test(el.textContent))
    render(null, el)
  })
}

test("an update answered managed names the store, even when status had no update_via", async () => {
  const box = mockBox({ store: "umbrel" })
  const fetchImpl = async (url, init) => url.endsWith("/status") ? new Response(JSON.stringify({ version: "1.0.0" }), { status: 200 }) : box(url, init)
  const el = await mount(fetchImpl)
  fire(button(el, "Check for update and install"), "click"); await tick(30)
  assert.match(el.textContent, /Update Nostr Vault from the Umbrel App Store\./)
  assert.ok(!/Updates are manual for now\. On the box/.test(el.textContent))
  render(null, el)
})

test("a box that doesn't answer says so on the card; a refused log says why and the rest still shows", async () => {
  const box = mockBox()
  const el = await mount(async (url, init) => url.endsWith("/status") ? new Response("{}", { status: 500 })
    : url.includes("/logs") ? new Response("{}", { status: 403 }) : box(url, init))
  assert.match(el.textContent, /Your box isn't answering/)
  assert.match(el.textContent, /Only the box's owner can do this/)
  assert.match(el.textContent, /usage 16600000000/)
  render(null, el)
})

test("box log lines become activity items: problems and heads-ups by their words, keys and paths redacted", () => {
  assert.equal(lineLevel("blossom: upload failed: disk full"), "problem")
  assert.equal(lineLevel("import: retrying relay.example in 30s"), "headsUp")
  assert.equal(lineLevel("box: engine started (pid 41)"), "good")
  const [it] = boxActivityItems([{ seq: 1, at: 1700000000, source: "engine", text: `saved ${"ab".repeat(32)} to /data/vault/blossom` }])
  assert.equal(it.at, 1700000000000)
  assert.equal(it.text, "saved [id] to [path]")
  assert.deepEqual(boxActivityItems(undefined), [])
  // As a real box logs (seen live): Go's date prefix and the engine's colour codes come off, not into "[path]".
  const [real] = boxActivityItems([{ seq: 2, at: 1, source: "engine", text: "2026/11/21 21:07:30 \u001b[32mINFO ✅ WoT initialized\u001b[0m" }])
  assert.equal(real.text, "INFO ✅ WoT initialized")
  assert.equal(boxActivityItems([{ seq: 3, at: 1, source: "engine", text: "\u001b[0m\t" }]).length, 0, "a colour-only line is left out")
})

test("on a box, #/relay and #/box open the Vault Dashboard; other addresses stay", () => {
  for (const h of ["#/relay", "#/box", "#/relay?x=1", "#/box/"]) assert.equal(boxDashboardRedirect(h), "#/vault?sheet=dashboard", h)
  for (const h of ["#/vault", "#/feed", "", "#/relayx", "#/settings/relays"]) assert.equal(boxDashboardRedirect(h), null, h)
})

test("Advanced in box mode: the box's uptime and version, and it runs on the box, not in this tab", () => {
  const sec = AdvancedSection({ box: { uptime: 3 * 86400 + 4 * 3600, version: "1.0.0" } })
  const lines = [sec.props.children].flat(3).filter(Boolean).flatMap(v => [v.props.children].flat(3)).filter(v => v?.props?.title).map(v => `${v.props.title}: ${v.props.value}`)
  assert.deepEqual(lines, ["Running for: 3d 4h", "Version: 1.0.0", "Runs on: Your box"])
  const unknown = AdvancedSection({ box: null })
  const vals = [unknown.props.children].flat(3).filter(Boolean).flatMap(v => [v.props.children].flat(3)).filter(v => v?.props?.title).map(v => v.props.value)
  assert.deepEqual(vals, ["—", "—", "Your box"], "unknown reads —")
})
