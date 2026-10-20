// After a payment the wallet's balance and History read again (Tron's PR 854 spend check): on a timeout Send says
// "check History before sending again", which only works if History shows the payment once it has happened. The
// iPhone reloads both after a send and after a timeout (WalletLightningTab+Send, +LNURL). Renders the cards (through
// Vite's SSR loader, for the JSX) into a small fake DOM; the wallet is a fake relay with throwaway keys.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip04 from "nostr-tools/nip04"
import { bytesToHex } from "nostr-tools/utils"

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
  addEventListener() {}
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
const { WalletHistory } = await vite.ssrLoadModule("/src/screens/WalletHistory.jsx")
const { Connected } = await vite.ssrLoadModule("/src/screens/WalletScreen.jsx")
const { payInvoice, onPaid, WalletError, WalletTimeout } = await vite.ssrLoadModule("/src/net/wallet.js")
test.after(() => vite.close())

const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const until = async (cond, what) => { for (let i = 0; i < 200; i++) { if (cond()) return; await tick(5) } assert.fail(`timed out waiting for ${what}`) }
const walletSk = generateSecretKey()
const conn = { walletPubkey: getPublicKey(walletSk), relay: "wss://relay.wallet.example", secret: bytesToHex(generateSecretKey()) }

/** A wallet relay that answers pay_invoice with `body`, or never answers when `body` is null. */
const wallet = body => async () => {
  const relay = {
    subscribe(_f, sub) { relay.sub = sub; queueMicrotask(() => sub.oneose()); return { close() {} } },
    async publish(req) {
      if (body) queueMicrotask(() => relay.sub.onevent(finalizeEvent({ kind: 23195, created_at: Math.floor(Date.now() / 1000),
        tags: [["p", req.pubkey], ["e", req.id]], content: nip04.encrypt(walletSk, req.pubkey, JSON.stringify(body)) }, walletSk)))
      return ""
    },
    close() {},
  }
  return relay
}
const paidCount = () => { const c = { n: 0 }; c.off = onPaid(() => c.n++); return c }

test("a payment that went through tells the wallet screens; one the wallet refused doesn't", async () => {
  const c = paidCount()
  await payInvoice(conn, "lnbc210n1x", { connect: wallet({ result: { preimage: "ab" } }) })
  assert.equal(c.n, 1)
  await assert.rejects(payInvoice(conn, "lnbc210n1x", { connect: wallet({ error: { code: "INSUFFICIENT_BALANCE", message: "no" } }) }), e => e instanceof WalletError)
  assert.equal(c.n, 1)
  c.off()
})

test("a payment with no answer in time tells them at once, and again a little later", async () => {
  const c = paidCount()
  await assert.rejects(payInvoice(conn, "lnbc210n1x", { connect: wallet(null), timeoutMs: 20, recheckMs: 30 }), e => e instanceof WalletTimeout)
  assert.equal(c.n, 1)
  await until(() => c.n === 2, "the second reload")
  c.off()
})

test("History reloads from the top after a payment, so it shows the payment", async () => {
  let calls = 0
  const list = async () => { calls++; return calls === 1 ? [] : [{ id: "p1", direction: "outgoing", state: "settled", sats: 21, feeSats: 0, description: "the payment", created_at: 1, zap: null }] }
  const el = document.createElement("div")
  render(h(WalletHistory, { wallet: { conn }, list }), el)
  // The empty state shows on the first render, before the card's effects (its first load, its listener) have run.
  await until(() => calls === 1 && /No payments yet/.test(el.textContent), "the first load")
  await tick(20)
  await payInvoice(conn, "lnbc210n1x", { connect: wallet({ result: { preimage: "ab" } }) })
  await until(() => /the payment/.test(el.textContent), "the payment in History")
  assert.equal(calls, 2)
  render(null, el)
})

test("the balance reads again after a payment", async () => {
  let balance = 100_000
  const el = document.createElement("div")
  render(h(Connected, { wallet: { conn }, balanceOf: async () => balance }), el)
  await until(() => /100 sats/.test(el.textContent), "the first balance")
  await tick(20)
  balance = 79_000
  await payInvoice(conn, "lnbc210n1x", { connect: wallet({ result: { preimage: "ab" } }) })
  await until(() => /79 sats/.test(el.textContent), "the new balance")
  render(null, el)
  // Unmounted cards stop listening.
  await payInvoice(conn, "lnbc210n1x", { connect: wallet({ result: { preimage: "ab" } }) })
})
