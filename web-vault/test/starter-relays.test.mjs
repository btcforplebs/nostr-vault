// Create an account's relay step (components/StarterRelays.jsx): the five, Continue, and Change to edit the list.
// Rendered through Vite's SSR loader (for the JSX) into a small fake DOM. Nothing is signed or sent here.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"

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

const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { StarterRelays } = await vite.ssrLoadModule("/src/components/StarterRelays.jsx")
const { NEW_ACCOUNT_RELAYS } = await vite.ssrLoadModule("/src/net/new-account.js")
test.after(() => vite.close())

const tick = () => new Promise(r => setTimeout(r, 0))
const all = (n, out = []) => { if (n.nodeType === 1) out.push(n); n.childNodes.forEach(c => all(c, out)); return out }
// preact's listener reads the event's type and runs on the element.
const fire = (n, name, extra = {}) => {
  // This DOM has no onclick property, so preact listens under "Click" rather than "click".
  const type = Object.keys(n.on ?? {}).find(k => k.toLowerCase() === name)
  if (!type) throw new Error(`no ${name} listener on ${n.localName}`)
  return n.on[type].call(n, { type, currentTarget: n, target: n, preventDefault() {}, stopPropagation() {}, ...extra })
}
const button = (el, label) => all(el).find(n => n.localName === "button" && n.textContent === label)

function mount() {
  const el = document.createElement("div"), state = { relays: NEW_ACCOUNT_RELAYS, continued: null }
  const draw = () => render(h(StarterRelays, { relays: state.relays, setRelays: r => { state.relays = r; draw() }, onContinue: r => { state.continued = r } }), el)
  draw()
  return { el, state }
}

test("the step names the servers, and Continue keeps exactly what it shows", async () => {
  const { el, state } = mount()
  assert.match(el.textContent, /Your posts will be shared through these servers/)
  for (const host of ["relay.primal.net", "relay.damus.io", "relay.snort.social", "relay.btcforplebs.com", "nostr-pub.wellorder.net"]) assert.ok(el.textContent.includes(host), host)
  assert.ok(button(el, "Change"), "a small Change link")
  assert.equal(button(el, "Remove"), undefined, "no editing until Change")
  const cont = button(el, "Continue")
  assert.ok(!("disabled" in cont.attributes) && cont.disabled !== true, "five servers: Continue is on")
  fire(button(el, "Continue"), "click")
  assert.deepEqual(state.continued, NEW_ACCOUNT_RELAYS)
  render(null, el)
})

test("Change: remove a server and add one; an unreachable address is refused; an empty list can't continue", async () => {
  const { el, state } = mount()
  fire(button(el, "Change"), "click"); await tick()
  fire(all(el).find(n => n.localName === "button" && n.attributes["aria-label"] === "Remove relay.damus.io"), "click"); await tick()
  assert.ok(!state.relays.includes("wss://relay.damus.io"))
  const input = all(el).find(n => n.localName === "input"), form = all(el).find(n => n.localName === "form")
  const type = async v => { fire(input, "input", { currentTarget: { value: v } }); await tick(); fire(form, "submit"); await tick() }
  await type("ws://localhost:3355")
  assert.match(el.textContent, /Use a wss:\/\/ address other people can reach/)
  await type("my.relay.example")
  assert.equal(state.relays.at(-1), "wss://my.relay.example")
  for (const url of [...state.relays]) { fire(all(el).find(n => n.attributes["aria-label"] === `Remove ${url.slice(6)}`), "click"); await tick() }
  assert.deepEqual(state.relays, [])
  const cont = button(el, "Continue")
  assert.ok(cont.disabled === true || "disabled" in cont.attributes, "a new account needs one server")
  render(null, el)
})
