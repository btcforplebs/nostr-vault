// Send (WalletLightningTab+Send, +LNURL; LightningPayTarget, LNURLAmountRange): what the box accepts, what an invoice
// will cost, and that an LNURL payment pays only an invoice for exactly the amount chosen. Nothing here reaches a
// network or a wallet: fetch and pay are fakes, and each records whether it was called.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { parsePayTarget, invoiceAmount, checkAmount, resolvePayTarget, payLnurl, payBolt11, plainMetadata } from "../src/net/wallet-send.js"

// A bech32 LNURL of https://service.example/lnurlp/bob, built the way decodeLnurl reads it.
const B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
function polymod(v) { const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; let c = 1; for (const x of v) { const t = c >>> 25; c = ((c & 0x1ffffff) << 5) ^ x; for (let i = 0; i < 5; i++) if ((t >>> i) & 1) c ^= G[i] } return c }
function lnurlOf(url) {
  const bytes = [...new TextEncoder().encode(url)], data = []
  let acc = 0, bits = 0
  for (const b of bytes) { acc = (acc << 8) | b; bits += 8; while (bits >= 5) { bits -= 5; data.push((acc >> bits) & 31) } }
  if (bits) data.push((acc << (5 - bits)) & 31)
  const hrp = [..."lnurl"].map(c => c.charCodeAt(0)), ex = [...hrp.map(c => c >> 5), 0, ...hrp.map(c => c & 31)]
  const mod = polymod([...ex, ...data, 0, 0, 0, 0, 0, 0]) ^ 1
  const chk = [0, 1, 2, 3, 4, 5].map(i => (mod >> (5 * (5 - i))) & 31)
  return "lnurl1" + [...data, ...chk].map(d => B32[d]).join("")
}

test("the box takes an invoice, an address, an LNURL and an LUD-17 link, bare or wrapped", () => {
  assert.deepEqual(parsePayTarget("  LNBC210N1PXYZ "), { kind: "invoice", invoice: "lnbc210n1pxyz" })
  assert.deepEqual(parsePayTarget("lightning:lnbc210n1pxyz"), { kind: "invoice", invoice: "lnbc210n1pxyz" })
  assert.deepEqual(parsePayTarget("lightning://lnbc210n1pxyz"), { kind: "invoice", invoice: "lnbc210n1pxyz" })
  assert.deepEqual(parsePayTarget("bitcoin:bc1qxyz?amount=0.001&lightning=LNBC210N1PXYZ"), { kind: "invoice", invoice: "lnbc210n1pxyz" })
  assert.equal(parsePayTarget("bitcoin:bc1qxyz?amount=0.001"), null, "on-chain only: not this wallet's")
  assert.deepEqual(parsePayTarget("Bob@Example.com"), { kind: "address", address: "bob@example.com" })
  assert.deepEqual(parsePayTarget("lntbob@getalby.com"), { kind: "address", address: "lntbob@getalby.com" }, "an address, not a testnet invoice")
  assert.deepEqual(parsePayTarget("lnurlp://service.example/lnurlp/bob"), { kind: "lnurl", url: "https://service.example/lnurlp/bob" })
  assert.deepEqual(parsePayTarget("lnurlp://abc.onion/p"), { kind: "lnurl", url: "http://abc.onion/p" })
  assert.deepEqual(parsePayTarget(lnurlOf("https://service.example/lnurlp/bob").toUpperCase()), { kind: "lnurl", url: "https://service.example/lnurlp/bob" })
  assert.deepEqual(parsePayTarget("lnurlw://service.example/w"), { kind: "withdraw" })
  for (const bad of ["", "hello", "bob@", "@example.com", "bob@localhost", "a@b@c.com", "nostr:npub1xyz"]) assert.equal(parsePayTarget(bad), null, bad)
})

test("what an invoice will cost: its amount, no amount, or unreadable", () => {
  assert.deepEqual(invoiceAmount("lnbc210n1pxyz"), { sats: 21 })
  assert.deepEqual(invoiceAmount("lnbc1pvjluezpp5qqq"), { unspecified: true })
  assert.deepEqual(invoiceAmount("lnbc21x1pxyz"), { unreadable: true })
})

test("an LNURL range in whole sats: min rounds up, max rounds down", () => {
  const r = { minMsat: 1500, maxMsat: 100_999 }
  assert.deepEqual(checkAmount(r, 1), { tooSmall: true, minSats: 2, maxSats: 100 })
  assert.equal(checkAmount(r, 2).msat, 2000)
  assert.deepEqual(checkAmount(r, 101), { tooLarge: true, minSats: 2, maxSats: 100 })
  assert.ok(checkAmount(r, 0).invalid && checkAmount(r, 1.5).invalid && checkAmount(r, NaN).invalid)
})

/** A fake LNURL service: `pages[url] -> body`. Records every URL asked. */
function service(pages) {
  const asked = []
  const fetchImpl = async u => {
    asked.push(u)
    const key = Object.keys(pages).find(k => u.startsWith(k))
    const body = key ? pages[key] : null
    return { ok: !!body, url: u, json: async () => typeof body === "function" ? body(new URL(u)) : body }
  }
  return { asked, fetchImpl }
}
const PAY = { tag: "payRequest", callback: "https://service.example/cb", minSendable: 1000, maxSendable: 1_000_000, commentAllowed: 10,
  metadata: JSON.stringify([["text/plain", "Pay Bob"], ["text/identifier", "bob@service.example"]]) }

test("an address resolves at its https well-known URL, with its range, comment length and note", async () => {
  const s = service({ "https://service.example/.well-known/lnurlp/bob": PAY })
  const p = await resolvePayTarget({ kind: "address", address: "bob@service.example" }, s.fetchImpl)
  assert.deepEqual(p, { callback: PAY.callback, minMsat: 1000, maxMsat: 1_000_000, commentAllowed: 10, note: "Pay Bob", host: "service.example" })
  assert.equal(plainMetadata("not json"), null)
})

test("a withdraw link, an insecure service or one that isn't a pay request is refused before any amount is asked", async () => {
  await assert.rejects(resolvePayTarget({ kind: "withdraw" }), /receive money/)
  const w = service({ "https://service.example/w": { tag: "withdrawRequest", callback: "https://service.example/x" } })
  await assert.rejects(resolvePayTarget({ kind: "lnurl", url: "https://service.example/w" }, w.fetchImpl), /receive money/)
  await assert.rejects(resolvePayTarget({ kind: "lnurl", url: "http://service.example/p" }, service({}).fetchImpl), /secure/)
  const odd = service({ "https://service.example/p": { tag: "payRequest", callback: "https://service.example/cb", minSendable: 0, maxSendable: 0 } })
  await assert.rejects(resolvePayTarget({ kind: "lnurl", url: "https://service.example/p" }, odd.fetchImpl), /amounts/)
})

test("an LNURL payment asks for the amount in msat with the comment cut to its limit, and pays that invoice", async () => {
  const s = service({ "https://service.example/cb": u => ({ pr: `lnbc${Number(u.searchParams.get("amount")) / 100}n1pxyz` }) })
  const paid = []
  const pay = { callback: PAY.callback, minMsat: 1000, maxMsat: 1_000_000, commentAllowed: 5, host: "service.example" }
  await payLnurl({}, pay, { sats: 21, comment: " thanks a lot " }, { fetchImpl: s.fetchImpl, pay: async (_c, inv) => { paid.push(inv); return "pre" } })
  const asked = new URL(s.asked[0])
  assert.equal(asked.searchParams.get("amount"), "21000")
  assert.equal(asked.searchParams.get("comment"), "thank")
  assert.deepEqual(paid, ["lnbc210n1pxyz"])
})

test("nothing is paid for an invoice of another amount, or an amount outside the range", async () => {
  const swapped = service({ "https://service.example/cb": { pr: "lnbc10u1pxyz" } })
  let paid = 0
  const payImpl = async () => { paid++; return "" }
  const pay = { callback: PAY.callback, minMsat: 1000, maxMsat: 1_000_000, commentAllowed: 0, host: "service.example" }
  await assert.rejects(payLnurl({}, pay, { sats: 21 }, { fetchImpl: swapped.fetchImpl, pay: payImpl }), /different amount, so nothing was sent/)
  await assert.rejects(payLnurl({}, pay, { sats: 5000 }, { fetchImpl: swapped.fetchImpl, pay: payImpl }), /1 to 1,000 sats/)
  assert.equal(paid, 0)
  assert.equal(swapped.asked.length, 1, "an out-of-range amount asks the service nothing")
})

test("a pasted invoice is handed to the wallet as it is", async () => {
  const paid = []
  await payBolt11({}, "lnbc210n1pxyz", { pay: async (_c, inv) => { paid.push(inv); return "pre" } })
  assert.deepEqual(paid, ["lnbc210n1pxyz"])
})

test("the Send card loads", async () => {
  registerHooks({
    load(url, context, next) {
      if (!url.endsWith(".jsx")) return next(url, context)
      const path = fileURLToPath(url)
      const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
      if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
      return { format: "module", source: code, shortCircuit: true }
    },
  })
  assert.equal(typeof (await import("../src/screens/WalletSend.jsx")).WalletSend, "function")
})
