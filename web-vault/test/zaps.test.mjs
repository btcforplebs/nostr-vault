// Zaps (NIP-57): the lightning address read as the iPhone reads it, only secure zap services used, the zap request
// tagged as ZapService tags it, nothing paid unless the invoice asks for exactly the amount chosen, and totals
// counted from receipts only the recipient's zap service published. Throwaway keys, a fake zap service and a fake
// wallet: nothing is paid and nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import {
  lightningOf, payEndpoint, decodeLnurl, isAllowedEndpoint, invoiceMsat, resolvePay, receiptRelays, zap, countReceipts, trustedReceipts, TRUST_PARALLEL,
  zapTotal, wantTotals, lightningAddressOf, ZAP_MESSAGE,
} from "../src/net/zaps.js"

const me = generateSecretKey(), bob = generateSecretKey(), service = generateSecretKey(), forger = generateSecretKey()
const pk = sk => getPublicKey(sk)
const now = Math.floor(Date.now() / 1000)
let n0 = 0
const note = (sk = bob) => finalizeEvent({ kind: 1, created_at: now - 60, tags: [], content: `note ${++n0}` }, sk)

const ctxFor = (relays = ["wss://relay.example.com"]) => ({
  session: { pubkey: pk(me) },
  signer: { signEvent: async t => finalizeEvent(t, me) },
  account: { relays: { read: relays, write: relays } },
  vault: { feed: { query: async () => [] } },
})
const wallet = { status: "ready", conn: { walletPubkey: "f".repeat(64), relay: "wss://w.example", secret: "1".repeat(64) }, defaultSats: 21 }

// A zap service at zaps.example for bob, answering with an invoice for `invoiceFor(msat)`. Records every URL asked.
function fakeService({ invoiceFor = msat => `lnbc${msat / 100}n1qqqqfake`, pay = {}, finalUrl } = {}) {
  const asked = []
  const fetchImpl = async (u) => {
    asked.push(u)
    const url = new URL(u)
    const json = url.pathname.startsWith("/.well-known/lnurlp/")
      ? { tag: "payRequest", callback: "https://zaps.example/cb/bob", minSendable: 1000, maxSendable: 100_000_000, metadata: "[]",
          allowsNostr: true, nostrPubkey: pk(service), ...pay }
      : { pr: invoiceFor(Number(url.searchParams.get("amount"))), routes: [] }
    return { ok: true, url: finalUrl ?? u, json: async () => json }
  }
  return { asked, fetchImpl }
}
const payer = () => { const paid = []; return { paid, pay: async (conn, pr) => { paid.push({ conn, pr }); return "ab".repeat(32) } } }
const bobLn = async () => ({ lud16: "Bob@Zaps.example" })

test("lud06 comes before lud16, as on the iPhone", () => {
  assert.deepEqual(lightningOf({ lud06: "LNURL1ABC", lud16: "bob@zaps.example" }), { lud06: "lnurl1abc" })
  assert.deepEqual(lightningOf({ lud16: " bob@zaps.example " }), { lud16: "bob@zaps.example" })
  assert.equal(lightningOf({}), null)
  assert.equal(lightningOf(undefined), null)
})

test("a lightning address is its https well-known endpoint; a bech32 LNURL is checksum-checked", () => {
  assert.equal(payEndpoint({ lud16: "Bob@Zaps.example" }), "https://zaps.example/.well-known/lnurlp/bob")
  assert.equal(payEndpoint({ lud16: "bob@evil.example/x" }), null)
  assert.equal(payEndpoint({ lud16: "bob" }), null)
  // The LUD-01 example.
  const lnurl = "LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS"
  assert.equal(decodeLnurl(lnurl), "https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df")
  assert.equal(decodeLnurl(lnurl.slice(0, -1) + "Q"), null, "a bad checksum")
  assert.equal(decodeLnurl("nostr1qqqq"), null)
})

test("only https zap services are used, or http to an onion", () => {
  assert.ok(isAllowedEndpoint("https://zaps.example/x"))
  assert.ok(isAllowedEndpoint("http://abc.onion/x"))
  assert.ok(!isAllowedEndpoint("http://zaps.example/x"))
  assert.ok(!isAllowedEndpoint("javascript:alert(1)"))
})

test("an invoice's exact amount: whole msat only, nothing for an amountless one", () => {
  assert.equal(invoiceMsat("lnbc210n1qqqq"), 21_000)
  assert.equal(invoiceMsat("LNBC2500U1QQQQ"), 250_000_000)
  assert.equal(invoiceMsat("lnbc1m1qqqq"), 100_000_000)
  assert.equal(invoiceMsat("lnbc210p1qqqq"), 21)
  assert.equal(invoiceMsat("lnbc215p1qqqq"), null, "not a whole msat")
  assert.equal(invoiceMsat("lnbc1qqqq"), null, "amountless: the separator is not an amount")
  assert.equal(invoiceMsat("lnbc99999999999999999991qqqq"), null)
  assert.equal(invoiceMsat("hello"), null)
})

test("receipts go to public relays only, ten at most", () => {
  const r = receiptRelays({ relays: { read: ["ws://localhost:3355", "wss://a.example/", "wss://192.168.1.4"], write: ["wss://a.example", "wss://box.local"] } })
  assert.deepEqual(r, ["wss://a.example", "wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"])
})

test("a note zap: the request is tagged as the iPhone tags it, and the invoice is paid from the wallet", async () => {
  const s = fakeService(), w = payer(), n = note()
  const out = await zap(ctxFor(), { recipient: n.pubkey, note: n, sats: 21 }, { fetchImpl: s.fetchImpl, pay: w.pay, wallet, lnOf: bobLn })
  assert.equal(out.preimage, "ab".repeat(32))
  assert.equal(s.asked[0], "https://zaps.example/.well-known/lnurlp/bob")
  const cb = new URL(s.asked[1])
  assert.equal(cb.origin + cb.pathname, "https://zaps.example/cb/bob")
  assert.equal(cb.searchParams.get("amount"), "21000")
  assert.equal(cb.searchParams.get("lnurl"), "Bob@Zaps.example")
  const req = JSON.parse(cb.searchParams.get("nostr"))
  assert.ok(verifyEvent(req))
  assert.equal(req.kind, 9734)
  assert.equal(req.pubkey, pk(me))
  assert.equal(req.content, ZAP_MESSAGE)
  assert.deepEqual(req.tags, [["p", n.pubkey], ["relays", "wss://relay.example.com", "wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"],
    ["amount", "21000"], ["e", n.id], ["lnurl", "Bob@Zaps.example"]])
  assert.deepEqual(w.paid, [{ conn: wallet.conn, pr: "lnbc210n1qqqqfake" }])
  assert.ok(!s.asked.some(u => u.includes(wallet.conn.secret)), "the wallet's secret is in no URL")
  assert.deepEqual(zapTotal(n.id), { sats: 21, mine: true })
})

test("a profile zap has no e tag", async () => {
  const s = fakeService(), w = payer()
  await zap(ctxFor(), { recipient: pk(bob), sats: 5 }, { fetchImpl: s.fetchImpl, pay: w.pay, wallet, lnOf: bobLn })
  const req = JSON.parse(new URL(s.asked[1]).searchParams.get("nostr"))
  assert.ok(!req.tags.some(t => t[0] === "e"))
  assert.equal(w.paid.length, 1)
})

test("nothing is paid for an invoice of another amount, an insecure service, or an amount it won't take", async () => {
  const n = note()
  const cases = [
    [fakeService({ invoiceFor: msat => `lnbc${msat / 100 + 10}n1qqqq` }), /different amount/],
    [fakeService({ invoiceFor: () => "lnbc1qqqq" }), /different amount/], // amountless
    [fakeService({ pay: { callback: "http://zaps.example/cb" } }), /secure/],
    [fakeService({ finalUrl: "http://zaps.example/.well-known/lnurlp/bob" }), /insecure/],
    [fakeService({ pay: { minSendable: 50_000 } }), /takes 50 to/],
    [fakeService({ pay: { tag: "withdrawRequest" } }), /isn't set up/],
  ]
  for (const [s, msg] of cases) {
    const w = payer()
    await assert.rejects(zap(ctxFor(), { recipient: n.pubkey, note: n, sats: 21 }, { fetchImpl: s.fetchImpl, pay: w.pay, wallet, lnOf: bobLn }), msg)
    assert.equal(w.paid.length, 0)
  }
  assert.equal(zapTotal(n.id).sats, 0)
})

test("no wallet, no lightning address, or a bad amount stops before anything is asked", async () => {
  const s = fakeService(), w = payer(), n = note()
  const go = (o, deps) => zap(ctxFor(), { recipient: n.pubkey, note: n, sats: 21, ...o }, { fetchImpl: s.fetchImpl, pay: w.pay, wallet, lnOf: bobLn, ...deps })
  await assert.rejects(go({}, { wallet: { status: "none" } }), /Connect a wallet/)
  await assert.rejects(go({}, { lnOf: async () => null }), /lightning address/)
  await assert.rejects(go({ sats: 0 }), /1 to 10,000,000/)
  await assert.rejects(go({ sats: 10_000_001 }), /1 to 10,000,000/)
  await assert.rejects(go({ sats: 1.5 }), /1 to 10,000,000/)
  assert.equal(s.asked.length, 0)
  assert.equal(w.paid.length, 0)
})

test("a signer that signs as someone else stops the zap before the invoice", async () => {
  const s = fakeService(), w = payer(), n = note()
  const ctx = { ...ctxFor(), signer: { signEvent: async t => finalizeEvent(t, forger) } }
  await assert.rejects(zap(ctx, { recipient: n.pubkey, note: n, sats: 21 }, { fetchImpl: s.fetchImpl, pay: w.pay, wallet, lnOf: bobLn }), /different account/)
  assert.equal(s.asked.length, 1)
  assert.equal(w.paid.length, 0)
})

// A kind 9735 for `target`, published by `by`, as a zap service builds it (the zap request in `description`).
const receipt = ({ target, sats, by = service, sender = me, recipient = pk(bob) }) => finalizeEvent({
  kind: 9735, created_at: now, content: "",
  tags: [["p", recipient], ["e", target], ["bolt11", `lnbc${sats * 10}n1qqqq`],
    ["description", JSON.stringify(finalizeEvent({ kind: 9734, created_at: now, content: "", tags: [["p", recipient], ["e", target]] }, sender))]],
}, by)

test("totals: each receipt once, only from the recipient's zap service, mine marked", async () => {
  const s = fakeService()
  const a = note(), b = note()
  const r1 = receipt({ target: a.id, sats: 100, sender: bob })
  await countReceipts([r1, r1, receipt({ target: a.id, sats: 21 }), receipt({ target: a.id, sats: 5000, by: forger }),
    receipt({ target: "0".repeat(64), sats: 7 }), { ...receipt({ target: b.id, sats: 9 }), kind: 7 }], [a.id, b.id], pk(me), bobLn, s.fetchImpl)
  assert.deepEqual(zapTotal(a.id), { sats: 121, mine: true })
  assert.deepEqual(zapTotal(b.id), { sats: 0, mine: false })
  // Asked once per recipient, however many receipts.
  assert.equal(s.asked.length, 1)
})

test("totals: a recipient whose zap service can't be resolved is trusted, as on the iPhone", async () => {
  const a = note(), stranger = generateSecretKey()
  await countReceipts([receipt({ target: a.id, sats: 3, by: forger, sender: bob, recipient: pk(stranger) })], [a.id], pk(me), async () => null)
  assert.deepEqual(zapTotal(a.id), { sats: 3, mine: false })
})

test("trusted receipts: only the payee's own zap service may publish one, and only with a real signed request", async () => {
  const s = fakeService()
  const a = note()
  const real = receipt({ target: a.id, sats: 21 })
  const forged = receipt({ target: a.id, sats: 1_200_000, by: forger }) // a real-looking receipt from someone else
  const unsigned = { ...real, tags: real.tags.map(t => t[0] === "description" ? ["description", JSON.stringify({ ...JSON.parse(t[1]), sig: "0".repeat(128) })] : t) }
  const other = note(bob) // not a receipt: passes untouched
  const kept = await trustedReceipts([real, forged, unsigned, other], bobLn, s.fetchImpl)
  assert.deepEqual(kept.map(e => e.id), [real.id, other.id])
})

test("trusted receipts: a payee whose zap service can't be resolved keeps receipts with a valid request (fails open)", async () => {
  const stranger = generateSecretKey(), a = note()
  const r = receipt({ target: a.id, sats: 3, by: forger, recipient: pk(stranger) })
  assert.deepEqual((await trustedReceipts([r], async () => null)).map(e => e.id), [r.id])
})

test("trusted receipts: payees' zap services are asked side by side, not one after another", async () => {
  // Ten payees nobody has asked yet, each lookup held open until all of them have started.
  const payees = Array.from({ length: 10 }, () => generateSecretKey())
  const rs = payees.map(p => receipt({ target: note().id, sats: 1, by: forger, recipient: pk(p) }))
  let inFlight = 0, most = 0, release
  const gate = new Promise(r => { release = r })
  const lnOf = async () => {
    most = Math.max(most, ++inFlight)
    if (inFlight >= TRUST_PARALLEL) release()
    await Promise.race([gate, new Promise(r => setTimeout(r, 200))])
    inFlight--
    return null
  }
  const kept = await trustedReceipts(rs, lnOf)
  assert.equal(most, TRUST_PARALLEL, "payees were looked up one at a time")
  assert.deepEqual(kept.map(e => e.id), rs.map(e => e.id), "order changed")
})

test("totals are asked in groups of ten, one filter per call, once per note", async () => {
  const calls = []
  const query = async (relays, filter) => { calls.push({ relays, filter }); return [] }
  const ids = Array.from({ length: 12 }, () => note().id)
  for (const id of ids) wantTotals(ctxFor(), id, { query, delayMs: 5 })
  wantTotals(ctxFor(), ids[0], { query, delayMs: 5 })
  await new Promise(r => setTimeout(r, 50))
  assert.equal(calls.length, 2)
  assert.ok(!Array.isArray(calls[0].filter))
  assert.deepEqual(calls[0].filter, { kinds: [9735], "#e": ids.slice(0, 10), limit: 500 })
  assert.deepEqual(calls[1].filter["#e"], ids.slice(10))
  assert.deepEqual(calls[0].relays, ["wss://relay.example.com", "wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"])
})

test("the lightning address comes from the newest kind 0 in Haven, lud06 included", async () => {
  const old = finalizeEvent({ kind: 0, created_at: now - 100, tags: [], content: JSON.stringify({ lud16: "old@zaps.example" }) }, bob)
  const cur = finalizeEvent({ kind: 0, created_at: now, tags: [], content: JSON.stringify({ lud06: "LNURL1XYZ", lud16: "bob@zaps.example" }) }, bob)
  const ctx = { ...ctxFor(), vault: { feed: { query: async () => [old, cur] } } }
  let asked = false
  assert.deepEqual(await lightningAddressOf(ctx, pk(bob), { query: async () => { asked = true; return [] } }), { lud06: "lnurl1xyz" })
  assert.ok(!asked, "Haven had it")
  const empty = { ...ctxFor(), vault: { feed: { query: async () => [] } } }
  assert.deepEqual(await lightningAddressOf(empty, pk(bob), { query: async () => [old] }), { lud16: "old@zaps.example" })
})

test("resolvePay keeps the service's receipt key only when it allows nostr", async () => {
  assert.equal((await resolvePay({ lud16: "bob@zaps.example" }, fakeService().fetchImpl)).nostrPubkey, pk(service))
  assert.equal((await resolvePay({ lud16: "bob@zaps.example" }, fakeService({ pay: { allowsNostr: false } }).fetchImpl)).nostrPubkey, null)
})

test("the zap button and Wallet screen load", async () => {
  registerHooks({
    load(url, context, next) {
      if (!url.endsWith(".jsx")) return next(url, context)
      const path = fileURLToPath(url)
      const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
      if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
      return { format: "module", source: code, shortCircuit: true }
    },
  })
  assert.equal(typeof (await import("../src/components/ZapButton.jsx")).ZapButton, "function")
  assert.equal(typeof (await import("../src/screens/WalletScreen.jsx")).WalletScreen, "function")
  assert.equal(typeof (await import("../src/components/ZappersList.jsx")).ZappersList, "function")
})

// Who zapped a note (ZappersListView): the zap request's signer, its sats and comment, biggest first. A receipt whose
// request doesn't hold up still counts toward the total, as before, but names nobody.
test("zappers: each is the zap request's signer with sats and comment, biggest first; an unchecked request names nobody", async () => {
  const { zappersOf } = await import("../src/net/zaps.js")
  const N = "7".repeat(64), RECIPIENT = getPublicKey(generateSecretKey())
  const aSk = generateSecretKey(), bSk = generateSecretKey()
  const req = (sk, content) => JSON.stringify(finalizeEvent({ kind: 9734, created_at: 1, tags: [["p", RECIPIENT], ["e", N]], content }, sk))
  let i = 0
  const receipt = (description, msat) => ({
    id: String(++i).padStart(64, "0"), kind: 9735, pubkey: "f".repeat(64), created_at: 100 + i, content: "",
    tags: [["p", RECIPIENT], ["e", N], ["bolt11", `lnbc${msat / 100}n1x`], ["description", description]],
  })
  const events = [receipt(req(aSk, " thanks! "), 21_000), receipt(req(bSk, ""), 1_000_000), receipt("{not a request", 5_000)]
  await countReceipts(events, [N], "0".repeat(64), async () => null)
  assert.equal(zapTotal(N).sats, 21 + 1000 + 5)
  assert.deepEqual(zappersOf(N).map(z => [z.sender, z.sats, z.comment]), [
    [getPublicKey(bSk), 1000, ""],
    [getPublicKey(aSk), 21, "thanks!"],
  ])
})
