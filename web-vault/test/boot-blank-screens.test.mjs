// Three boots that looked broken (nv-ui, 2026-11-10): a lazily loaded screen drew nothing while its chunk loaded and
// nothing at all offline; a screen drew before its stylesheets landed (and the Feed before the 17 sheets its own
// components ask for); and a first sign-in opened on "No Following Feed" when the follow list was on a relay slower
// than the account's grace. Rendered into a small fake DOM; relays stubbed, nothing is sent anywhere.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync, existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"
import { transformSync } from "rolldown/utils"
import { h, render } from "preact"
import { pool } from "../src/net/pool.js"
import { refreshAccount } from "../src/net/sync.js"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const p = fileURLToPath(url)
    const { code, errors } = transformSync(p, readFileSync(p, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

// Just enough DOM for preact to render into and for the test to read back (as box-screen.test.mjs).
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes; return s ? s[s.indexOf(this) + 1] ?? null : null }
  insertBefore(n, ref) { n.parentNode?.removeChild(n); const i = ref ? this.childNodes.indexOf(ref) : -1; i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n); n.parentNode = this; return n }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { (this.on ??= {})[type] = fn }
  removeEventListener() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(globalThis.document.createTextNode(v)) }
}
// The page's <link rel="stylesheet"> elements, for sheetsIn: `sheet` stays null until the test loads one.
const links = []
const link = () => {
  const on = {}
  const l = { sheet: null, addEventListener: (type, fn) => { (on[type] ??= []).push(fn) }, fire: type => { if (type === "load") l.sheet = {}; (on[type] ?? []).forEach(f => f()) } }
  links.push(l)
  return l
}
globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
  querySelectorAll: sel => sel === 'link[rel="stylesheet"]' ? links : [],
}
const winListeners = {}
globalThis.addEventListener = (type, fn) => { (winListeners[type] ??= new Set()).add(fn) }
globalThis.removeEventListener = (type, fn) => { winListeners[type]?.delete(fn) }

globalThis.requestAnimationFrame ??= cb => setTimeout(cb, 0) // preact runs effects after the next frame
globalThis.cancelAnimationFrame ??= id => clearTimeout(id)
const { lazyScreen, sheetsIn } = await import("../src/screens/lazy.jsx")

const tick = (ms = 5) => new Promise(r => setTimeout(r, ms))
const until = async (ok, ms = 1000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (ok()) return true; await tick() } return !!ok() }
const all = (n, out = []) => { if (n.nodeType === 1) out.push(n); n.childNodes.forEach(c => all(c, out)); return out }
const held = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b }); return { promise, resolve, reject } }
const click = n => { const type = Object.keys(n.on ?? {}).find(k => k.toLowerCase() === "click"); return n.on[type].call(n, { type, currentTarget: n, target: n, preventDefault() {}, stopPropagation() {} }) }
const mount = vnode => { const root = new Node(1, "div"); render(vnode, root); return root }
const Real = ({ name }) => h("main", { class: "screen real" }, `the ${name} screen`)

// 1. Lazily loaded screens.

test("a screen whose chunk is still loading draws the screen's box with placeholder rows, not nothing", async () => {
  const chunk = held()
  const Screen = lazyScreen("Real", () => chunk.promise)
  const root = mount(h(Screen, { name: "slow" }))
  await tick()
  const main = all(root).find(n => n.localName === "main")
  assert.ok(main, "something is drawn while the chunk loads")
  assert.equal(main.attributes["aria-busy"], "true", "and it says it is loading")
  assert.match(root.textContent, /Loading…/)
  chunk.resolve({ Real })
  await tick()
  assert.equal(root.textContent, "the slow screen")
})

test("offline, a chunk that didn't load says so and comes in on Try again", async () => {
  let tries = 0
  const Screen = lazyScreen("Retry", () => ++tries === 1 ? Promise.reject(new TypeError("Failed to fetch dynamically imported module")) : Promise.resolve({ Retry: Real }))
  Object.defineProperty(globalThis, "navigator", { value: { onLine: false }, configurable: true })
  const root = mount(h(Screen, { name: "retried" }))
  await tick()
  assert.match(root.textContent, /offline, so this screen couldn't load/, "not an empty page")
  const retry = all(root).find(n => n.localName === "button" && n.textContent === "Try again")
  assert.ok(retry, "with a way out")
  click(retry)
  await tick()
  assert.equal(root.textContent, "the retried screen")
  assert.equal(tries, 2)
})

test("back online, a screen that failed asks for its chunk again by itself", async () => {
  let tries = 0
  // A key of its own: each screen's chunk is asked for once per page.
  const Online = ({ name }) => h("main", null, `online ${name}`)
  const Screen = lazyScreen("Online", () => ++tries === 1 ? Promise.reject(new TypeError("offline")) : Promise.resolve({ Online }))
  Object.defineProperty(globalThis, "navigator", { value: { onLine: false }, configurable: true })
  const root = mount(h(Screen, { name: "again" }))
  assert.ok(await until(() => /couldn't load/.test(root.textContent)), root.textContent)
  assert.ok(await until(() => winListeners.online?.size), "it listens for the browser coming back online")
  Object.defineProperty(globalThis, "navigator", { value: { onLine: true }, configurable: true })
  for (const f of winListeners.online) f()
  assert.ok(await until(() => root.textContent === "online again"), root.textContent)
})

// 3, for lazy screens: their stylesheets are in before they draw.

test("a screen waits for the stylesheets its chunk added before it draws", async () => {
  links.length = 0
  const Styled = () => h("main", null, "styled")
  const Screen = lazyScreen("Styled", () => { const l = link(); return Promise.resolve({ Styled, l }) })
  const root = mount(h(Screen))
  await tick(20)
  assert.match(root.textContent, /Loading…/, "the chunk is in, its sheet isn't: still the placeholder")
  links[0].fire("load")
  await tick()
  assert.equal(root.textContent, "styled")
})

test("sheetsIn: nothing pending is no wait; a failed sheet or a slow one doesn't hold the screen", async () => {
  links.length = 0
  let done = false
  await sheetsIn().then(() => { done = true })
  assert.ok(done)
  const failing = link()
  const p = sheetsIn()
  failing.fire("error")
  await p
  links.length = 0
  link()
  const t0 = Date.now()
  await sheetsIn(globalThis.document, 30)
  assert.ok(Date.now() - t0 < 1000, "gave up on the sheet after its limit")
  links.length = 0
})

// 3, for the boot bundle: every sheet its own components ask for at run time is in the boot stylesheet.

const root = fileURLToPath(new URL("..", import.meta.url))
function bootSheets() {
  const seen = new Set(), sheets = new Map(), static_ = new Set()
  const resolve = (from, spec) => { const p = path.resolve(path.dirname(from), spec); return [p, `${p}.js`, `${p}.jsx`].find(c => existsSync(c) && /\.(m?js|jsx)$/.test(c)) }
  const visit = f => {
    // The pinned list itself isn't walked: the question is what the components ask for, and whether it's in that list.
    if (seen.has(f) || f.endsWith(path.join("styles", "boot-sheets.js"))) return
    seen.add(f)
    const src = readFileSync(f, "utf8")
    // Static imports only: `import x from "./y"` and `import "./y"`, never import(): that is a chunk of its own.
    for (const m of src.matchAll(/^\s*import\s+(?:[^"'();]*?\s+from\s+)?["'](\.[^"']+)["']/gm)) {
      if (m[1].endsWith(".css")) static_.add(path.resolve(path.dirname(f), m[1])) // already in the boot stylesheet
      const r = resolve(f, m[1]); if (r) visit(r)
    }
    for (const m of src.matchAll(/^\s*if \(import\.meta\.env\)\s*\{?([^\n]*)/gm))
      for (const c of m[1].matchAll(/import\(["']([^"']+\.css)["']\)/g)) sheets.set(path.resolve(path.dirname(f), c[1]), path.relative(root, f))
  }
  visit(path.join(root, "main.jsx"))
  for (const css of static_) sheets.delete(css)
  return sheets
}

test("every stylesheet a boot component asks for at run time is pinned in the boot stylesheet", () => {
  const sheets = bootSheets()
  assert.ok(sheets.size >= 10, `found the boot components' sheets (${sheets.size})`) // the walk itself works
  assert.ok(sheets.has(path.join(root, "src/styles/feeds.css")), "the Feed's own sheet is among them")
  assert.match(readFileSync(path.join(root, "main.jsx"), "utf8"), /^import "\.\/src\/styles\/boot-sheets\.js"/m, "main.jsx imports the pinned list")
  const pinnedFile = path.join(root, "src/styles/boot-sheets.js")
  const pinned = new Set([...readFileSync(pinnedFile, "utf8").matchAll(/^import "([^"]+\.css)"/gm)].map(m => path.resolve(path.dirname(pinnedFile), m[1])))
  const missing = [...sheets].filter(([css]) => !pinned.has(css)).map(([css, by]) => `${path.relative(root, css)} (asked for by ${by})`)
  assert.deepEqual(missing, [], "a sheet asked for at run time lands after the first paint: add it to src/styles/boot-sheets.js")
})

// 2. First sign-in: the follow list on a relay slower than the grace.

const me = "a".repeat(64), them = "b".repeat(64)
const ev = (kind, created_at, tags = []) => ({ id: `${kind}-${created_at}`, pubkey: me, kind, created_at, tags, content: "", sig: "" })
const fakeVault = () => { const evs = []; return { evs, outbox: { async event(e) { evs.push(e); return { ok: true } }, async query() { return evs } } } }

test("the profile on a fast relay and the follow list on a slow one: no follow list yet, then onLate brings it", async t => {
  const slow = held()
  t.mock.method(pool, "querySync", relays => relays.includes("wss://slow.example") ? slow.promise : Promise.resolve([ev(0, 20)]))
  t.mock.method(pool, "ensureRelay", async () => ({}))
  let late = null
  const got = await refreshAccount(fakeVault(), me, ["wss://fast.example", "wss://slow.example"], { onLate: a => { late = a } })
  assert.equal(got.contacts, undefined, "the grace ended on the profile alone")
  assert.equal(late, null, "nothing late until the slow relay has answered")
  slow.resolve([ev(3, 10, [["p", them]])])
  await tick(30)
  assert.ok(late, "onLate ran once every relay had answered")
  assert.deepEqual(late.follows, [them], "with the follow list the slow relay had")
})

test("onLate is only for an account that came back with no follow list", async t => {
  t.mock.method(pool, "querySync", async () => [ev(0, 20), ev(3, 10, [["p", them]])])
  t.mock.method(pool, "ensureRelay", async () => ({}))
  let calls = 0
  const got = await refreshAccount(fakeVault(), me, ["wss://one.example"], { onLate: () => calls++ })
  await tick(30)
  assert.deepEqual(got.follows, [them])
  assert.equal(calls, 0)
})

test("boot keeps 'Loading your follows…' until the follow list is in, on both of its account paths", () => {
  const main = readFileSync(path.join(root, "main.jsx"), "utf8")
  const calls = [...main.matchAll(/await (refreshAccount|prepareVault)\(([\s\S]*?)\)\n/g)]
  assert.deepEqual(calls.map(c => c[1]).sort(), ["prepareVault", "refreshAccount"])
  for (const [, name, args] of calls) assert.match(args, /onLate: lateAccount/, `${name} hands the late follow list back`)
  // An account with no follow list isn't "loaded": the Feed says "Loading your follows…", not "No Following Feed".
  assert.doesNotMatch(main, /setAccount\(\{ \.\.\.(fresh|ready), loaded: true \}\)/)
  assert.match(main, /const settled = acc => late \? \{ \.\.\.late, loaded: true \} : \{ \.\.\.acc, loaded: !!acc\.contacts \}/)
  assert.match(readFileSync(path.join(root, "src/net/vault-ready.js"), "utf8"), /\{ log, early, onLate \}\)/, "prepareVault passes it to refreshAccount")
})
