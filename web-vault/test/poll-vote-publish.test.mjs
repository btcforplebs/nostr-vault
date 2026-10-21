// The vote call site (FeedKinds PollBody): a stranger's poll must not choose how many hosts get your signed vote. The
// real PollBody is rendered and an option tapped; the test counts the relays pool.publish is handed. Test keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { h, render } from "preact"
import { pool } from "../src/net/pool.js"
import { setActionContext } from "../src/net/actions.js"

// Node can't load .jsx: compile it with Vite's Oxc transform, as in thread-repost.test.mjs.
registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { KindBody } = await import("../src/components/FeedKinds.jsx")

// Just enough DOM for preact to render PollBody into, with click listeners the test can fire.
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
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { this.on[type.toLowerCase()] = { type, fn } }
  removeEventListener(type) { delete this.on[type.toLowerCase()] }
  click() { const { type, fn } = this.on.click; fn.call(this, { type, stopPropagation() {}, preventDefault() {} }) }
  all(pred) { return [...(pred(this) ? [this] : []), ...this.childNodes.flatMap(c => c.all?.(pred) ?? [])] }
}
globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))

test("tapping an option on a 504-relay-tag poll sends the vote to at most 8 public relays", async () => {
  const author = generateSecretKey(), voter = generateSecretKey()
  const tags = [["option", "y", "Yes"], ["option", "n", "No"],
    ...Array.from({ length: 400 }, (_, i) => ["relay", `wss://r${i}.example`]),
    ...Array.from({ length: 100 }, () => ["relay", "wss://dup.example"]),
    ["relay", "ws://127.0.0.1"], ["relay", "wss://192.168.1.2"], ["relay", "wss://100.64.1.1"], ["relay", "wss://[64:ff9b::7f00:1]"]]
  const poll = finalizeEvent({ kind: 1068, created_at: Math.floor(Date.now() / 1000), content: "Which?", tags }, author)

  const published = []
  const orig = { publish: pool.publish, querySync: pool.querySync }
  pool.publish = (urls, ev) => { published.push({ urls: [...urls], kind: ev.kind }); return urls.map(() => Promise.resolve("ok")) }
  pool.querySync = async () => []
  setActionContext({
    session: { pubkey: getPublicKey(voter) },
    signer: { signEvent: async t => finalizeEvent(t, voter) },
    account: { relays: { read: [], write: ["wss://mine.example"] } },
    vault: { outbox: { event: async () => {}, query: async () => [] } },
  })
  const root = document.createElement("div")
  try {
    render(h(KindBody, { event: poll }), root)
    await tick()
    const yes = root.all(n => n.localName === "button" && n.attributes["aria-label"] === "Yes")[0]
    assert.ok(yes, "the Yes option renders")
    yes.click()
    for (let i = 0; i < 50 && published.length < 2; i++) await tick(2)

    const votes = published.filter(p => p.kind === 1018)
    assert.equal(votes[0]?.urls[0], "wss://mine.example", "first to your own write relays (publishAction)")
    const fanOut = votes[1]?.urls ?? []
    assert.equal(fanOut.length, 8, `the poll's relays: ${fanOut.length}`)
    assert.equal(new Set(fanOut).size, 8, "no duplicates")
    for (const u of fanOut) assert.match(u, /^wss:\/\/r\d+\.example$/, "no loopback, LAN, CGNAT or NAT64 host")
  } finally {
    render(null, root)
    Object.assign(pool, orig)
    setActionContext(null)
  }
})
