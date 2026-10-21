// Zaps in wallet History from their public receipts (the iPhone's ZapHistoryService / ZapReceipt): payment hash read
// from bolt11, matched by hash else invoice, conflicting receipts give nothing, a receipt counts only when the zapped
// person's own zap service published it (fails closed), the zap must involve you, and the zapped posts come along.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { paymentHashOf, receiptOf, matchReceipts, receiptFilters, lookupZaps } from "../src/net/wallet-zaps.js"

// --- a test-only bolt11 writer: hrp, 7 timestamp words, a `p` field, a zero signature, a valid bech32 checksum.
const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
function polymod(values) {
  const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; let chk = 1
  for (const v of values) { const b = chk >>> 25; chk = ((chk & 0x1ffffff) << 5) ^ v; for (let i = 0; i < 5; i++) if ((b >>> i) & 1) chk ^= G[i] }
  return chk
}
const toWords = hex => { const out = []; let acc = 0, bits = 0; for (const byte of Buffer.from(hex, "hex")) { acc = (acc << 8) | byte; bits += 8; while (bits >= 5) { bits -= 5; out.push((acc >> bits) & 31) } } if (bits) out.push((acc << (5 - bits)) & 31); return out }
function invoice(hashHex, hrp = "lnbc210n") {
  const p = toWords(hashHex)
  const data = [...Array(7).fill(1), 1, Math.floor(p.length / 32), p.length % 32, ...p, ...Array(104).fill(0)]
  const expand = [...[...hrp].map(c => c.charCodeAt(0) >> 5), 0, ...[...hrp].map(c => c.charCodeAt(0) & 31)]
  const mod = polymod([...expand, ...data, 0, 0, 0, 0, 0, 0]) ^ 1
  const check = Array.from({ length: 6 }, (_, i) => (mod >> (5 * (5 - i))) & 31)
  return hrp + "1" + [...data, ...check].map(w => CHARSET[w]).join("")
}

const H1 = "11".repeat(32), H2 = "22".repeat(32), H3 = "33".repeat(32)
const meSk = generateSecretKey(), ME = getPublicKey(meSk)
const zapperSk = generateSecretKey(), ZAPPER = getPublicKey(zapperSk)
const serviceSk = generateSecretKey(), SERVICE = getPublicKey(serviceSk) // ME's zap service
const forgerSk = generateSecretKey()
const NOTE = "e".repeat(64)
const zapRequest = (sk, to, content = "", extra = []) => JSON.stringify(finalizeEvent({ kind: 9734, created_at: 1000, content, tags: [["p", to], ...extra] }, sk))
const receipt = (sk, hash, req, at = 1100) => finalizeEvent({ kind: 9735, created_at: at, content: "", tags: [["p", ME], ["bolt11", invoice(hash)], ["description", req]] }, sk)

test("the payment hash comes out of a bolt11 (BOLT 11's own test vector), and a bad checksum gives none", () => {
  const spec = "lnbc1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq8rkx3yf5tcsyz3d73gafnh3cax9rn449d9p5uxz9ezhhypd0elx87sjle52x86fux2ypatgddc6k63n7erqz25le42c4u4ecky03ylcqca784w"
  assert.equal(paymentHashOf(spec), "0001020304050607080900010203040506070809000102030405060708090102")
  assert.equal(paymentHashOf(spec.slice(0, -1) + "q"), null)
  assert.equal(paymentHashOf(invoice(H1)), H1)
  assert.equal(paymentHashOf("not an invoice"), null)
})

test("receipts match by hash, else by invoice; two different stories about one payment give neither", () => {
  const a = receiptOf(receipt(serviceSk, H1, zapRequest(zapperSk, ME, "one")))
  const b1 = receiptOf(receipt(serviceSk, H2, zapRequest(zapperSk, ME, "two")))
  const b2 = receiptOf(receipt(serviceSk, H2, zapRequest(zapperSk, ME, "a different two")))
  const c = receiptOf(receipt(serviceSk, H3, zapRequest(zapperSk, ME, "three")))
  const txs = [{ id: H1 }, { id: H2 }, { id: invoice(H3) }, { id: "outgoing-5-1" }]
  const m = matchReceipts(txs, [a, b1, b2, c])
  assert.equal(m.get(H1).comment, "one")
  assert.equal(m.has(H2), false, "conflicted")
  assert.equal(m.get(invoice(H3)).comment, "three", "a tx known only by its invoice still matches, through its hash")
  assert.equal(m.size, 2)
  const same = receiptOf(receipt(serviceSk, H1, zapRequest(zapperSk, ME, "one")))
  assert.equal(matchReceipts([{ id: H1 }], [a, same]).size, 1, "the same story twice is fine")
})

test("receipt filters ask #p and #P for the page's span, with slack for late receipts", () => {
  const f = receiptFilters([{ created_at: 5000 }, { created_at: 9000 }], ME)
  assert.deepEqual(f.map(x => [Object.keys(x).find(k => k.startsWith("#")), x.since, x.until]), [["#p", 4400, 12600], ["#P", 4400, 12600]])
})

const fitsMe = (d, direction) => (direction === "incoming" ? d.recipient === ME : d.anonymous || d.sender === ME)
const post = finalizeEvent({ kind: 1, created_at: 900, content: "my\nnote", tags: [] }, meSk)

test("lookup: only receipts the zapped person's service published count; forged and unsigned ones don't; posts come along", async () => {
  const good = receipt(serviceSk, H1, zapRequest(zapperSk, ME, "", [["e", post.id]]))
  const forged = receipt(forgerSk, H2, zapRequest(zapperSk, ME, "refund me at evil.example"))
  const tampered = { ...receipt(serviceSk, H3, zapRequest(zapperSk, ME, "x")), content: "changed" }
  const asked = []
  const query = async (relays, f) => { asked.push(f); return f.ids ? [post] : [good, forged, tampered, good] }
  const txs = [{ id: H1, direction: "incoming", created_at: 1000 }, { id: H2, direction: "incoming", created_at: 1000 }, { id: H3, direction: "incoming", created_at: 1000 }, { id: "x", direction: "incoming", created_at: 1000, zap: { noteId: null } }]
  const r = await lookupZaps(txs, ME, { relays: ["wss://r"], query, publisherOf: async pk => (pk === ME ? SERVICE : null), fits: fitsMe })
  assert.deepEqual([...r.details.keys()], [H1])
  assert.equal(r.details.get(H1).sender, ZAPPER)
  assert.equal(r.posts.get(post.id).content, "my\nnote")
  assert.ok(asked.some(f => f["#p"]) && asked.some(f => f["#P"]))
})

test("lookup fails closed: no zap service key means no story; a zap not involving you is dropped", async () => {
  const good = receipt(serviceSk, H1, zapRequest(zapperSk, ME, "hi"))
  const query = async (r, f) => (f.ids ? [] : [good])
  const tx = [{ id: H1, direction: "incoming", created_at: 1000 }]
  assert.equal((await lookupZaps(tx, ME, { relays: [], query, publisherOf: async () => null, fits: fitsMe })).details.size, 0)
  assert.equal((await lookupZaps(tx, ME, { relays: [], query, publisherOf: async () => { throw new Error("offline") }, fits: fitsMe })).details.size, 0)
  const out = [{ id: H1, direction: "outgoing", created_at: 1000 }]
  assert.equal((await lookupZaps(out, ME, { relays: [], query, publisherOf: async () => SERVICE, fits: fitsMe })).details.size, 0, "an outgoing payment with someone else's zap")
  assert.equal((await lookupZaps(tx, null, { relays: [], query, publisherOf: async () => SERVICE, fits: fitsMe })).details.size, 0)
})

test("transactions the wallet already explained aren't looked up", async () => {
  let asked = 0
  const r = await lookupZaps([{ id: H1, direction: "incoming", created_at: 1, zap: { noteId: null } }], ME, { relays: [], query: async () => { asked++; return [] }, publisherOf: async () => SERVICE, fits: fitsMe })
  assert.equal(asked, 0)
  assert.equal(r.details.size, 0)
})
