// Messages is one of the Vault's pages (Logen, 2026-11-03): it left the Vault toolbar, so no list wears the envelope,
// and it is picked from the Vault menu top left, which the Messages page wears too, with the unread count on its item.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
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
  contains(n) { for (; n; n = n.parentNode) if (n === this) return true; return false }
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}
globalThis.document = { createElement: n => new Node(1, n), createElementNS: (_, n) => new Node(1, n), createTextNode: d => Object.assign(new Node(3, "#text"), { data: String(d) }) }
globalThis.addEventListener = () => {}
globalThis.removeEventListener = () => {}
globalThis.location = { hash: "#/vault" }

const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
after(() => vite.close())
const { VaultPagesMenu, pagesMenuText, MESSAGES_PAGE } = await vite.ssrLoadModule("/src/screens/VaultPagesMenu.jsx")
const { MODES } = await vite.ssrLoadModule("/src/net/vault-lists.js")
const src = f => readFileSync(new URL(`../${f}`, import.meta.url), "utf8")
const all = (n, pred, out = []) => { if (pred(n)) out.push(n); for (const c of n.childNodes ?? []) all(c, pred, out); return out }
const click = n => { const [type, fn] = Object.entries(n.on).find(([k]) => /^click$/i.test(k)); fn.call(n, { type, target: n }) } // preact's proxy reads its handlers off `this`

test("the pill names the page open; Messages' count and the dot for news elsewhere", () => {
  assert.equal(pagesMenuText("followers", new Set(), 0).page.title, "Followers")
  const onMessages = pagesMenuText("messages", new Set(), 4)
  assert.equal(onMessages.page, MESSAGES_PAGE)
  assert.equal(onMessages.count, "4")
  assert.equal(onMessages.elsewhere, false, "on Messages, its own unread aren't news elsewhere")
  assert.equal(onMessages.title, "Vault: Messages, 4 unread messages")
  const onVault = pagesMenuText("activity", new Set(), 1)
  assert.equal(onVault.elsewhere, true, "an unread message dots the pill on every Vault list")
  assert.equal(onVault.title, "Vault: Vault, 1 unread message")
  assert.equal(pagesMenuText("notes", new Set(), 0).count, null)
  assert.equal(pagesMenuText("notes", new Set(), 0).elsewhere, false)
  assert.equal(pagesMenuText("notes", new Set(["zaps"]), 0).elsewhere, true)
  assert.equal(pagesMenuText("notes", new Set(), 250).count, "99+")
})

test("the menu lists the Vault's pages, then Messages, Bookmarks, Emoji and Notifications, then the Dashboard; a pick opens the page", async () => {
  const host = new Node(1, "div"), picked = []
  const ctx = { session: { pubkey: "a".repeat(64) }, account: { follows: [] }, vault: {} }
  await act(() => render(h(VaultPagesMenu, { ctx, current: "followers", onPick: id => picked.push(id) }), host))
  const pill = all(host, n => n.localName === "button" && n.attributes["aria-haspopup"] === "menu")[0]
  assert.match(pill.textContent, /Followers/)
  await act(() => click(pill))
  const items = all(host, n => n.attributes?.role === "menuitem").map(n => n.textContent)
  assert.deepEqual(items, [...MODES.map(m => m.title), "Messages", "Bookmarks", "Emoji", "Notifications", "Vault Dashboard"], "no Refresh: the pages look again on their own")
  await act(() => click(all(host, n => n.attributes?.role === "menuitem" && n.textContent === "Notes")[0]))
  assert.deepEqual(picked, ["notes"], "a list switches in place on the Vault tab")
  // The menu closes on a pick through its wrapper (a bubbled click this fake DOM doesn't send): open it if it shut.
  if (!all(host, n => n.attributes?.role === "menuitem").length) await act(() => click(pill))
  await act(() => click(all(host, n => n.attributes?.role === "menuitem" && n.textContent === "Messages")[0]))
  assert.equal(location.hash, "#/messages", "Messages opens as its own page")
  await act(() => render(null, host))
})

test("on the Messages page the menu opens a Vault list at #/vault/<mode>", async () => {
  const host = new Node(1, "div")
  const ctx = { session: { pubkey: "a".repeat(64) }, account: { follows: [] }, vault: {} }
  location.hash = "#/messages"
  await act(() => render(h(VaultPagesMenu, { ctx, current: "messages" }), host))
  const pill = all(host, n => n.localName === "button" && n.attributes["aria-haspopup"] === "menu")[0]
  assert.match(pill.textContent, /Messages/)
  await act(() => click(pill))
  const items = all(host, n => n.attributes?.role === "menuitem").map(n => n.textContent)
  assert.ok(!items.includes("Refresh"))
  await act(() => click(all(host, n => n.attributes?.role === "menuitem" && n.textContent === "Followers")[0]))
  assert.equal(location.hash, "#/vault/followers")
  await act(() => render(null, host))
})

test("no Vault list wears the envelope; the phone's Messages page wears the Vault menu, the desktop column doesn't", () => {
  const vault = src("src/screens/VaultScreen.jsx")
  assert.doesNotMatch(vault, /href="#\/messages"/, "the toolbar envelope is gone")
  assert.doesNotMatch(vault, /ICONS\.envelope/)
  assert.match(vault, /<VaultPagesMenu ctx=\{ctx\} current=\{mode\}/)
  assert.match(src("main.jsx"), /route === "messages" && !nappletsOn\(\) && <MessagesScreen ctx=\{ctx\} vaultMenu \/>/)
  assert.match(src("main.jsx"), /<MessagesPane ctx=\{ctx\} open=\{route === "dm" \? arg : null\} vaultMenu \/>/, "the napplet page wears it too (P7)")
  assert.match(src("src/screens/MessagesScreen.jsx"), /vaultMenu && <VaultPagesMenu ctx=\{ctx\} current="messages" \/>/)
  assert.match(src("src/desktop/DesktopShell.jsx"), /<MessagesScreen ctx=\{ctx\} \/>/, "the desktop's column: no menu")
})
