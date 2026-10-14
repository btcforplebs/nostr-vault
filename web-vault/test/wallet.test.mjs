// Wallet Connect (NIP-47): the link read as the iPhone reads it, requests signed with the link's secret and answered
// only by the wallet, the link kept sealed in a store sign-out deletes, and never repeated in an error.
// A fake wallet with throwaway keys answers in place of a relay: nothing is paid and nothing leaves the machine.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import * as nip04 from "nostr-tools/nip04"
import { bytesToHex } from "nostr-tools/utils"
import {
  parseWalletUri, walletRequest, getBalance, payInvoice, WalletError, WalletTimeout, sealUri, openUri, walletDbName,
  loadWallet, connectWallet, disconnectWallet, setDefaultZap, walletState, DEFAULT_ZAP_SATS,
} from "../src/net/wallet.js"
import { storeNames } from "../src/haven/vault.js"

const walletSk = generateSecretKey(), appSk = generateSecretKey()
const walletPk = getPublicKey(walletSk), secret = bytesToHex(appSk)
const uri = (o = {}) => `nostr+walletconnect://${o.pk ?? walletPk}?relay=${encodeURIComponent(o.relay ?? "wss://relay.wallet.example")}&secret=${o.secret ?? secret}`
const conn = { walletPubkey: walletPk, relay: "wss://relay.wallet.example", secret }

// A relay with a wallet behind it. `answer(request) -> { result } | { error }`, or `respond(request, sub)` to send
// whatever the test wants. Records what the app sent and whether it closed.
function fakeWallet({ answer = () => ({ result: {} }), respond, eose = true } = {}) {
  const seen = { published: [], filters: [], closed: false, url: null }
  const relay = {
    subscribe(filters, sub) {
      seen.filters.push(filters)
      if (eose) queueMicrotask(() => sub.oneose?.())
      relay.sub = sub
      return { close() {} }
    },
    async publish(ev) {
      seen.published.push(ev)
      queueMicrotask(() => {
        if (respond) return respond(ev, relay.sub)
        relay.sub.onevent(reply(ev, answer(JSON.parse(nip04.decrypt(walletSk, ev.pubkey, ev.content)))))
      })
      return ""
    },
    close() { seen.closed = true },
  }
  return { seen, connect: async url => { seen.url = url; return relay } }
}
const reply = (req, body, sk = walletSk) => finalizeEvent({
  kind: 23195, created_at: Math.floor(Date.now() / 1000), tags: [["p", req.pubkey], ["e", req.id]],
  content: nip04.encrypt(sk, req.pubkey, JSON.stringify(body)),
}, sk)

test("a wallet link is read with or without // and with its relay and secret", () => {
  assert.deepEqual(parseWalletUri(uri()), conn)
  assert.deepEqual(parseWalletUri("  " + uri().replace("nostr+walletconnect://", "nostr+walletconnect:") + "\n"), conn)
  assert.equal(parseWalletUri(uri({ relay: "wss://relay.wallet.example/" })).relay, "wss://relay.wallet.example")
})

test("a bad link is refused, and the error never repeats the secret", () => {
  for (const bad of ["", "lnbc1...", uri({ pk: "abc" }), uri({ secret: "nothex" }), uri({ relay: "https://relay.wallet.example" }),
    uri({ relay: "ws://relay.wallet.example" }), `nostr+walletconnect://${walletPk}?secret=${secret}`]) {
    assert.throws(() => parseWalletUri(bad), e => !e.message.includes(secret) && !e.message.includes(walletPk))
  }
  // Plain ws:// only to this machine (a wallet on the same Mac, or a test).
  assert.equal(parseWalletUri(uri({ relay: "ws://127.0.0.1:7777" })).relay, "ws://127.0.0.1:7777")
})

test("a request is a kind 23194 signed by the link's secret, encrypted to the wallet, sent after the subscription", async () => {
  const w = fakeWallet({ answer: req => ({ result_type: req.method, result: { balance: 21_000 } }) })
  assert.equal(await getBalance(conn, { connect: w.connect }), 21_000)
  const [req] = w.seen.published
  assert.equal(w.seen.url, conn.relay)
  assert.equal(req.kind, 23194)
  assert.equal(req.pubkey, getPublicKey(appSk))
  assert.ok(verifyEvent({ ...JSON.parse(JSON.stringify(req)) }))
  assert.deepEqual(req.tags, [["p", walletPk]])
  assert.ok(!req.content.includes("get_balance"), "the request is encrypted")
  assert.deepEqual(JSON.parse(nip04.decrypt(walletSk, req.pubkey, req.content)), { method: "get_balance", params: {} })
  assert.deepEqual(w.seen.filters[0], [{ kinds: [23195], authors: [walletPk], "#e": [req.id] }])
  assert.ok(w.seen.closed, "the relay is closed after the answer")
})

test("pay_invoice sends the invoice and returns the preimage", async () => {
  let asked
  const w = fakeWallet({ answer: req => { asked = req; return { result_type: "pay_invoice", result: { preimage: "ab".repeat(32) } } } })
  assert.equal(await payInvoice(conn, "lnbc210n1fake", { connect: w.connect }), "ab".repeat(32))
  assert.deepEqual(asked, { method: "pay_invoice", params: { invoice: "lnbc210n1fake" } })
})

test("the wallet's error comes back with its code", async () => {
  const w = fakeWallet({ answer: () => ({ result_type: "pay_invoice", error: { code: "INSUFFICIENT_BALANCE", message: "Not enough sats" } }) })
  await assert.rejects(payInvoice(conn, "lnbc1", { connect: w.connect }), e => e instanceof WalletError && e.code === "INSUFFICIENT_BALANCE" && e.message === "Not enough sats")
  assert.ok(w.seen.closed)
})

test("an answer from anyone but the wallet, or for another request, is ignored until the timeout", async () => {
  const stranger = generateSecretKey()
  const w = fakeWallet({ respond: (req, sub) => {
    sub.onevent(reply(req, { result: { preimage: "forged" } }, stranger))
    sub.onevent(finalizeEvent({ kind: 23195, created_at: 1, tags: [["e", "0".repeat(64)]], content: nip04.encrypt(walletSk, req.pubkey, '{"result":{}}') }, walletSk))
  } })
  await assert.rejects(payInvoice(conn, "lnbc1", { connect: w.connect, timeoutMs: 50 }),
    e => e instanceof WalletTimeout && /may still go through/.test(e.message))
  assert.ok(w.seen.closed)
})

test("a relay that can't be reached is said plainly, without the link", async () => {
  await assert.rejects(getBalance(conn, { connect: async () => { throw new Error(`refused ${uri()}`) } }),
    e => e.message === "Couldn't reach your wallet's relay.")
})

test("the link is sealed: the stored record holds no part of it in the clear", async () => {
  const sealed = await sealUri(uri())
  const bytes = new Uint8Array(sealed.data)
  assert.ok(!Buffer.from(bytes).toString("latin1").includes(secret.slice(0, 16)))
  assert.equal(sealed.key.extractable, false, "the key can't be read back out")
  assert.equal(await openUri(sealed), uri())
})

// A record store as idbStore keeps it, in memory.
const memStore = () => { let v; return { get: async () => v, put: async x => { v = structuredClone(x) }, peek: () => v } }

test("connect, reload, change the default zap, disconnect: the record is the only place it lives", async () => {
  const s = memStore()
  await loadWallet("a".repeat(64), s)
  assert.deepEqual(walletState(), { status: "none", defaultSats: DEFAULT_ZAP_SATS })
  await connectWallet(uri())
  assert.equal(walletState().status, "ready")
  assert.deepEqual(walletState().conn, conn)
  assert.ok(!JSON.stringify(s.peek(), (k, v) => v instanceof ArrayBuffer ? "buf" : v).includes(secret))
  await setDefaultZap("21")
  await loadWallet("a".repeat(64), s) // a reload
  assert.equal(walletState().status, "ready")
  assert.equal(walletState().defaultSats, 21)
  await assert.rejects(setDefaultZap("0"))
  await assert.rejects(setDefaultZap("10000001"))
  await disconnectWallet()
  assert.deepEqual(s.peek(), { defaultSats: 21 })
  assert.deepEqual(walletState(), { status: "none", defaultSats: 21 })
})

test("a bad link isn't saved", async () => {
  const s = memStore()
  await loadWallet("b".repeat(64), s)
  await assert.rejects(connectWallet(uri({ secret: "zz" })))
  assert.equal(s.peek(), undefined)
})

test("sign-out's store wipe takes the wallet's store, and only this account's", async () => {
  const me = "c".repeat(64), other = "d".repeat(64)
  const idb = { databases: async () => [walletDbName(me), walletDbName(other)].map(name => ({ name })) }
  const names = await storeNames(me, idb)
  assert.ok(names.includes(walletDbName(me)))
  assert.ok(!names.includes(walletDbName(other)))
})
