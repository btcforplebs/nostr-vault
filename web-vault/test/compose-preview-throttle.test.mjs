// Compose preview keeps up while you type (2026-11-27, Tidy's RESEARCH/NV_COMPOSE_PREVIEW_DELAY_2026_11_27.md): a
// ~150 ms throttle in place of the 350 ms debounce that restarted at every key (typing faster than one key per 350 ms
// froze the preview until you stopped), and a guard that stays mounted instead of being keyed on the event id (which
// remounted the whole card at every redraw). The real ComposePreview is rendered into a tiny fake DOM; real timers.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { h, render } from "preact"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.on = {}
    // Properties, so preact sets them as properties (as on a real textarea) instead of attributes.
    if (localName === "textarea") { this.value = ""; this.readOnly = false }
  }
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
  addEventListener(type, fn) { this.on[type.toLowerCase()] = { type, fn } }
  removeEventListener(type) { delete this.on[type.toLowerCase()] }
  fire(name, extra = {}) { const { type, fn } = this.on[name]; fn.call(this, { type, currentTarget: this, target: this, stopPropagation() {}, preventDefault() {}, ...extra }) }
  click() { this.fire("click") }
  focus() { focusedNode = this }
  setSelectionRange() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  all(pred) { return [...(pred(this) ? [this] : []), ...this.childNodes.flatMap(c => c.all?.(pred) ?? [])] }
}
globalThis.document = {
  body: new Node(1, "body"),
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}
let focusedNode = null

const { ComposePreview, PREVIEW_THROTTLE_MS, throttleWait, showsFailure } = await import("../src/screens/compose/ComposePreview.jsx")
const sleep = ms => new Promise(r => setTimeout(r, ms))
const pubkey = getPublicKey(generateSecretKey())

test("the wait: none a full window after the last redraw, else the rest of that window", () => {
  assert.equal(PREVIEW_THROTTLE_MS, 150)
  assert.equal(throttleWait(1000, 1200), 0)
  assert.equal(throttleWait(1000, 1150), 0)
  assert.equal(throttleWait(1000, 1100), 50)
  assert.equal(throttleWait(1000, 1000), 150)
})

test("a failure note only holds for the event that failed", () => {
  assert.equal(showsFailure(null, "a"), false)
  assert.equal(showsFailure("a", "a"), true)
  assert.equal(showsFailure("a", "b"), false, "the next edit tries again")
})

test("typing faster than the window: the preview keeps changing during the burst, on the same card", async () => {
  let text = "h"
  const build = () => ({ content: text, tags: [] })
  const root = new Node(1, "div")
  const draw = () => render(h(ComposePreview, { build, pubkey, deps: [text] }), root)
  draw()
  await sleep(60)
  const card = () => root.all(n => n.localName === "article")[0]
  const first = card()
  assert.ok(first, "the first text shows at once")
  const seen = new Set([root.textContent])
  // 24 keys at 60 ms (about 16 keys/s): 1.4 s of typing. The old 350 ms debounce showed nothing new until the end.
  for (let i = 0; i < 24; i++) {
    text += "x"; draw()
    await sleep(60)
    seen.add(root.textContent)
  }
  const duringBurst = seen.size
  assert.ok(duringBurst >= 5, `the preview moved ${duringBurst - 1} times while typing; want it to keep up`)
  await sleep(PREVIEW_THROTTLE_MS + 100)
  assert.match(root.textContent, new RegExp(`${text}`), "the last key shows soon after typing stops")
  assert.ok(card() === first, "the card is diffed, not remounted")
  render(null, root)
})
