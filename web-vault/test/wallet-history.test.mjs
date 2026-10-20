// Wallet history (NIP-47 list_transactions), as the iPhone reads it (WalletTransaction, ZapDetail): loose number
// types, state from `state` or `settled_at`, pages merged newest first, and a zap request in the description believed
// only when its signature holds. Throwaway keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { WalletError } from "../src/net/wallet.js"
import { parseTransaction, mergeTransactions, zapDetailOf, counterparty, isUnsupported, listTransactions } from "../src/net/wallet-history.js"

const senderSk = generateSecretKey(), SENDER = getPublicKey(senderSk)
const ME = "a".repeat(64), NOTE = "b".repeat(64)
const zapRequest = (tags, content = "") => JSON.stringify(finalizeEvent({ kind: 9734, created_at: 1000, tags, content }, senderSk))

test("a transaction: millisats to sats, numbers as strings or floats, state from settled_at when there is no state", () => {
  const t = parseTransaction({ type: "incoming", amount: "21000", fees_paid: 0, created_at: 1700000000.0, settled_at: "1700000005", payment_hash: "ABC", description: "coffee" })
  assert.deepEqual(t, { id: "abc", direction: "incoming", state: "settled", sats: 21, feeSats: 0, description: "coffee", created_at: 1700000000, settled_at: 1700000005, zap: null })
  assert.equal(parseTransaction({ type: "outgoing", amount: 5000, created_at: 1 }).state, "pending")
  assert.equal(parseTransaction({ type: "outgoing", amount: 5000, created_at: 1, state: "FAILED", settled_at: 2 }).state, "failed")
  assert.equal(parseTransaction({ type: "outgoing", amount: 5000, fees_paid: 2999, created_at: 1 }).feeSats, 2)
})

test("an entry with no direction or no time is dropped; one with neither hash nor invoice still gets an id", () => {
  assert.equal(parseTransaction({ type: "sideways", created_at: 1 }), null)
  assert.equal(parseTransaction({ type: "incoming", amount: 1000 }), null)
  assert.equal(parseTransaction(null), null)
  assert.equal(parseTransaction({ type: "incoming", amount: 1000, created_at: 5 }).id, "incoming-5-1")
})

test("pages merge newest first, and a payment on two pages appears once", () => {
  const a = { id: "1", created_at: 10 }, b = { id: "2", created_at: 30 }, c = { id: "3", created_at: 20 }
  assert.deepEqual(mergeTransactions([a, b], [b, c]).map(t => t.id), ["2", "3", "1"])
})

test("a signed zap request in the description is a zap: sender, recipient, post and comment", () => {
  const t = parseTransaction({ type: "incoming", amount: 21000, created_at: 1, description: zapRequest([["p", ME], ["e", NOTE]], " great post ") })
  assert.deepEqual(t.zap, { sender: SENDER, recipient: ME, noteId: NOTE, comment: "great post", anonymous: false })
  assert.equal(t.description, null, "the JSON is not shown as a description")
  assert.equal(counterparty(t), SENDER)
  assert.equal(counterparty({ ...t, direction: "outgoing" }), ME)
})

test("a forged or unsigned zap request is no zap: anyone can put JSON in an invoice's description", () => {
  const good = JSON.parse(zapRequest([["p", ME]]))
  const forged = JSON.stringify({ ...good, pubkey: "c".repeat(64) })
  const unsigned = JSON.stringify({ ...good, sig: undefined })
  for (const d of [forged, unsigned, "{not json", JSON.stringify({ kind: 1, pubkey: SENDER, tags: [] })]) assert.equal(zapDetailOf(d), null)
  assert.equal(zapDetailOf("lunch money"), null)
})

test("an anonymous zap names nobody", () => {
  const t = parseTransaction({ type: "incoming", amount: 1000, created_at: 1, description: zapRequest([["p", ME], ["anon", ""]]) })
  assert.equal(t.zap.anonymous, true)
  assert.equal(counterparty(t), null)
})

test("history that the wallet won't share is told apart from a failure", () => {
  for (const code of ["NOT_IMPLEMENTED", "RESTRICTED", "UNAUTHORIZED"]) assert.ok(isUnsupported(new WalletError(code)))
  assert.ok(!isUnsupported(new WalletError("INTERNAL")))
  assert.ok(!isUnsupported(new Error("relay down")))
})

test("a page is asked for with limit, offset and unpaid false, and comes back parsed", async () => {
  let asked
  const fakeRequest = async (_conn, method, params) => { asked = { method, params }; return { transactions: [{ type: "incoming", amount: 1000, created_at: 1 }, { bogus: true }] } }
  const page = await listTransactions({}, { limit: 20, offset: 40 }, { request: fakeRequest })
  assert.deepEqual(asked, { method: "list_transactions", params: { limit: 20, offset: 40, unpaid: false } })
  assert.equal(page.length, 1)
})

test("the History card loads", async () => {
  registerHooks({
    load(url, context, next) {
      if (!url.endsWith(".jsx")) return next(url, context)
      const path = fileURLToPath(url)
      const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
      if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
      return { format: "module", source: code, shortCircuit: true }
    },
  })
  assert.equal(typeof (await import("../src/screens/WalletHistory.jsx")).WalletHistory, "function")
})
