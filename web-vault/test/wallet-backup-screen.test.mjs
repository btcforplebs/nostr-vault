// The Wallet screen's "Your Nostr account" card (screens/WalletBackup.jsx): the iPhone's states, words and buttons
// (WalletSettingsView accountBackupSection), and that a save or removal goes to the account the card showed. Renders
// through Vite's SSR loader into a small fake DOM; nwc-backup.js is replaced by fakes, so nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { act } from "preact/test-utils"

class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.on = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes; return s ? s[s.indexOf(this) + 1] ?? null : null }
  insertBefore(n, ref) { n.parentNode?.removeChild(n); const i = ref ? this.childNodes.indexOf(ref) : -1; i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n); n.parentNode = this; return n }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { this.on[type] = fn }
  removeEventListener() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}
globalThis.document = { createElement: n => new Node(1, n), createElementNS: (_, n) => new Node(1, n), createTextNode: d => Object.assign(new Node(3, "#text"), { data: String(d) }) }

const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
test.after(() => vite.close())
const { WalletBackup } = await vite.ssrLoadModule("/src/screens/WalletBackup.jsx")
const W = await vite.ssrLoadModule("/src/net/wallet.js")

const hex = n => n.toString(16).padStart(64, "0")
const URI = `nostr+walletconnect://${hex(0xabc)}?relay=wss://relay.example&secret=${hex(0x5ec)}`
const OTHER = `nostr+walletconnect://${hex(0xdef)}?relay=wss://relay.example&secret=${hex(0x5ed)}`
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const all = (n, pred, out = []) => { if (pred(n)) out.push(n); for (const c of n.childNodes ?? []) all(c, pred, out); return out }
const fire = (n, name, e = {}) => { const [type, fn] = Object.entries(n.on).find(([k]) => k.toLowerCase() === name); return fn.call(n, { type, target: n, currentTarget: n, ...e }) }
const isOn = n => n.checked ?? (n.attributes.checked !== undefined && n.attributes.checked !== "false")
const button = (host, text) => all(host, n => n.localName === "button" && n.textContent === text)[0]
const ctxOf = (pubkey, method = "local") => ({ session: { method, pubkey }, signer: { readOnly: method === "readonly" } })

/** The wallet in use (wallet.js state): linked to `uri`, or none. */
async function linkWallet(uri) {
  let rec = null
  const store = { get: async () => rec, put: async v => { rec = v } }
  await W.loadWallet(hex(1), store)
  if (uri) await W.connectWallet(uri)
  return W.walletState()
}

async function mount({ status, wallet, ctx = ctxOf(hex(7)) }) {
  const calls = { save: [], clear: [] }
  const host = new Node(1, "div")
  let cur = ctx
  const props = {
    wallet, current: () => cur,
    read: async () => status,
    save: async (lock, uri) => { calls.save.push({ pubkey: lock.pubkey, uri }) },
    clear: async lock => { calls.clear.push(lock.pubkey) },
  }
  await act(() => render(h(WalletBackup, props), host))
  await act(() => tick(5))
  return { host, calls, text: () => host.textContent, switchTo: c => { cur = c }, rerender: () => act(() => render(h(WalletBackup, props), host)) }
}

test("nothing linked, nothing saved: says so, and offers to check again", async () => {
  const m = await mount({ status: { state: "empty" }, wallet: await linkWallet(null) })
  assert.match(m.text(), /No wallet saved on your Nostr account\./)
  assert.ok(button(m.host, "Check again"))
  assert.ok(!button(m.host, "Remove from my account"))
})

test("no relay answered: can't say, check again, and Remove is still offered", async () => {
  const m = await mount({ status: { state: "unknown" }, wallet: await linkWallet(URI) })
  assert.match(m.text(), /Couldn't check your Nostr account for a saved wallet\./)
  assert.ok(button(m.host, "Remove from my account"))
})

test("a wallet saved, none linked here: Use saved wallet links it", async () => {
  const m = await mount({ status: { state: "saved", uri: URI, savedAt: 1_700_000_000 }, wallet: await linkWallet(null) })
  assert.match(m.text(), /It may have come from Nostr Vault on another device or from Wisp\./)
  await act(() => fire(button(m.host, "Use saved wallet"), "click"))
  await act(() => tick(20))
  assert.equal(W.walletState().status, "ready")
  assert.ok(W.isCurrentWallet(URI))
})

test("the wallet in use is the one saved: the switch is on, and turning it off removes it from the account", async () => {
  const m = await mount({ status: { state: "saved", uri: URI, savedAt: 1 }, wallet: await linkWallet(URI) })
  const sw = all(m.host, n => n.attributes?.role === "switch")[0]
  assert.equal(isOn(sw), true)
  assert.ok(!button(m.host, "Remove from my account"), "the switch removes it")
  await act(() => fire(sw, "change", { currentTarget: { checked: false } }))
  await act(() => tick(5))
  assert.deepEqual(m.calls.clear, [hex(7)])
})

test("another wallet is saved: the switch is off, says turning it on replaces it, and saves the one in use", async () => {
  const m = await mount({ status: { state: "saved", uri: OTHER, savedAt: 1 }, wallet: await linkWallet(URI) })
  assert.match(m.text(), /Your account holds a different wallet, saved .*\. Turning this on replaces it\./)
  const sw = all(m.host, n => n.attributes?.role === "switch")[0]
  assert.equal(isOn(sw), false)
  await act(() => fire(sw, "change", { currentTarget: { checked: true } }))
  await act(() => tick(20))
  assert.deepEqual(m.calls.save, [{ pubkey: hex(7), uri: URI }], "the link in use, opened only for the save")
  assert.doesNotMatch(m.text(), /walletconnect/, "the link is never on screen")
})

test("a bunker's slot waits for Load with signer; Save this wallet instead and Remove are offered", async () => {
  const m = await mount({ status: { state: "needsSigner", savedAt: 1 }, wallet: await linkWallet(URI), ctx: ctxOf(hex(7), "nip46") })
  assert.match(m.text(), /Your signer has to open it\./)
  for (const b of ["Load with signer", "Save this wallet instead", "Remove from my account"]) assert.ok(button(m.host, b), b)
})

test("a read-only sign-in sees the slot but gets no buttons that would need a key", async () => {
  const m = await mount({ status: { state: "unreadable", savedAt: 1 }, wallet: await linkWallet(URI), ctx: ctxOf(hex(7), "readonly") })
  assert.match(m.text(), /this browser can't read it/)
  assert.match(m.text(), /This sign-in can't encrypt\./)
  for (const b of ["Try again", "Save this wallet instead", "Remove from my account"]) assert.ok(!button(m.host, b), b)
})

test("after a switch to another account, a tap refuses and checks again instead of saving for the wrong one", async () => {
  const m = await mount({ status: { state: "empty" }, wallet: await linkWallet(URI) })
  m.switchTo(ctxOf(hex(8)))
  const sw = all(m.host, n => n.attributes?.role === "switch")[0]
  await act(() => fire(sw, "change", { currentTarget: { checked: true } }))
  await act(() => tick(5))
  assert.deepEqual(m.calls.save, [])
  assert.match(m.text(), /The account changed\. Nothing was published; check again\./)
})
