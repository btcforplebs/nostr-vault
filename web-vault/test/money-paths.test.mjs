// Three web money paths (Tod, nv-parity 2026-11-10), each pinned so a revert fails here:
//  1. a zap receipt whose zap service can't be looked up proves nothing, so it is left out (fails closed);
//  2. Popular looks up a zap service only for receipts that could vote, each payee once, with the trust set and the
//     day's engagement asked side by side;
//  3. no payment over the send cap (wallet.js MAX_SEND_SATS) reaches the wallet.
// Throwaway keys, fake relays, a fake zap service and a fake wallet: nothing is paid and nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { countReceipts, trustedReceipts, receiptTrust, zapTotal, lightningAddressesOf } from "../src/net/zaps.js"
import { fetchPopular } from "../src/net/popular.js"
import { MAX_SEND_SATS, payInvoice, sendCapRefusal } from "../src/net/wallet.js"
import { checkAmount, payBolt11, payLnurl } from "../src/net/wallet-send.js"

const key = () => { const sk = generateSecretKey(); return { sk, pk: getPublicKey(sk) } }
const now = 1_762_800_000
const note = (who, i) => finalizeEvent({ kind: 1, created_at: now - 600, tags: [], content: `note ${i}` }, who.sk)
// A NIP-57 receipt for `noteId`, paid by `sender` to `payee`, published by `publisher`.
const receipt = ({ noteId, payee, sender, publisher, sats = 21 }) => finalizeEvent({
  kind: 9735, created_at: now - 60, content: "",
  tags: [["p", payee], ["e", noteId], ["bolt11", `lnbc${sats * 10}n1qqqq`],
    ["description", JSON.stringify(finalizeEvent({ kind: 9734, created_at: now - 61, content: "", tags: [["p", payee], ["e", noteId]] }, sender.sk))]],
}, publisher.sk)
const service = pubkey => async u => ({ ok: true, url: u, json: async () => ({ tag: "payRequest", callback: "https://zaps.example/cb", allowsNostr: true, nostrPubkey: pubkey }) })

test("1. a receipt whose zap service can't be looked up is left out, wherever receipts are counted", async () => {
  const payee = key(), sender = key(), anyone = key()
  const n = note(payee, 1)
  const r = receipt({ noteId: n.id, payee: payee.pk, sender, publisher: anyone })
  for (const [why, lnOf] of [["no lightning address", async () => null], ["the lookup threw", async () => { throw new Error("down") }]]) {
    assert.deepEqual(await trustedReceipts([r], lnOf), [], `trustedReceipts kept it: ${why}`)
  }
  await countReceipts([r], [n.id], sender.pk, async () => null)
  assert.equal(zapTotal(n.id).sats, 0, "a note total counted it")
  // No ctx: nothing can be looked up, so the receipt goes, and nothing is asked (no miss is recorded for later).
  const other = { kind: 1, id: "x" }
  assert.deepEqual(await receiptTrust(null)([r, other]), [other])
  // The same receipt from the payee's own service is kept: the rule is the lookup, not the receipt.
  const own = receipt({ noteId: n.id, payee: key().pk, sender, publisher: anyone })
  assert.deepEqual((await trustedReceipts([own], async () => ({ lud16: "p@zaps.example" }), service(anyone.pk))).map(e => e.id), [own.id])
})

test("2. Popular: only receipts that could vote cost a zap service lookup, each payee once, trust set and engagement asked together", async () => {
  const me = key(), friends = [key(), key(), key()], author = key()
  const target = note(author, 2)
  const zapService = key()
  // Three trusted friends zap one note, all to one payee. Sixty strangers each zap a different payee: they can't vote,
  // so their payees must not be looked up.
  const voting = friends.map(f => receipt({ noteId: target.id, payee: author.pk, sender: f, publisher: zapService }))
  const strangers = Array.from({ length: 60 }, (_, i) => {
    const payee = key(), stranger = key()
    return receipt({ noteId: note(payee, 100 + i).id, payee: payee.pk, sender: stranger, publisher: key() })
  })
  const follows = [...friends, author].map(f => f.pk)
  let engagementAsked = false, trustSetFirst = false
  const query = async (relays, f) => {
    if (f.kinds?.[0] === 3) {
      // Asked together, the engagement query has already gone out when the trust set's contact lists are asked.
      if (!engagementAsked) trustSetFirst = true
      return friends.map(fr => finalizeEvent({ kind: 3, created_at: now - 9_000, content: "", tags: follows.map(p => ["p", p]) }, fr.sk))
    }
    if (f.ids) return f.ids.includes(target.id) ? [target] : []
    if (f.limit === 5000) { engagementAsked = true; return [...voting, ...strangers] }
    return []
  }
  const looked = []
  const trust = evs => trustedReceipts(evs, async pk => { looked.push(pk); return { lud16: "a@zaps.example" } }, service(zapService.pk))
  const got = await fetchPopular({ me: me.pk, follows, relays: ["wss://r.example"], now, trust, query })
  assert.ok(engagementAsked)
  assert.ok(!trustSetFirst, "the day's engagement waited for the trust set")
  assert.deepEqual(looked, [author.pk], "a stranger's zap was looked up, or a payee twice")
  assert.deepEqual(got.notes.map(n => n.id), [target.id], "the three trusted zaps still lift the note")
  assert.equal(got.scores.get(target.id), 9, "three zaps, 3 each")
})

test("2b. the payees' profiles are read in one go, not one relay ask per payee", async () => {
  const sender = key(), svc = key()
  const payees = Array.from({ length: 30 }, key)
  const rs = payees.map((p, i) => receipt({ noteId: note(p, 200 + i).id, payee: p.pk, sender, publisher: svc }))
  const batches = []
  const kept = await trustedReceipts(rs, async () => assert.fail("one profile read per payee"), service(svc.pk), {
    lnOfMany: async pks => { batches.push(pks.length); return new Map(pks.map(pk => [pk, { lud16: "a@zaps.example" }])) },
  })
  assert.deepEqual(batches, [30])
  assert.equal(kept.length, 30)
  // Known payees aren't read again; the batch read itself asks the relays once per 250 people.
  await trustedReceipts(rs, null, service(svc.pk), { lnOfMany: async () => assert.fail("read again") })
  const asks = []
  const many = Array.from({ length: 300 }, (_, i) => i.toString(16).padStart(64, "0"))
  const ctx = { account: { relays: { read: ["wss://r.example"] } }, vault: { feed: { query: async () => [] } } }
  const got = await lightningAddressesOf(ctx, many, { query: async (r, f) => { asks.push(f.authors.length); return [] } })
  assert.deepEqual(asks, [250, 50])
  assert.equal(got.size, 300)
})

test("3. nothing over the send cap reaches the wallet, on any path", async () => {
  const conn = { walletPubkey: key().pk, relay: "wss://w.example", secret: "1".repeat(64) }
  let asked = 0
  const connect = async () => { asked++; throw new Error("wallet asked") }
  const sats = n => `lnbc${n * 10}n1qqqq` // n sats
  assert.equal(MAX_SEND_SATS, 10_000_000)
  // One sat over the cap, and an invoice whose amount can't be read: refused before the wallet is asked.
  for (const inv of [sats(MAX_SEND_SATS + 1), "lnbc1btc1qqqq", "lnbc1"]) {
    assert.ok(sendCapRefusal(inv), inv)
    await assert.rejects(payInvoice(conn, inv, { connect }), /most Nostr Vault sends|can't read this invoice's amount/)
    await assert.rejects(payBolt11(conn, inv), /most Nostr Vault sends|can't read this invoice's amount/)
  }
  assert.equal(asked, 0, "the wallet was asked to pay an invoice over the cap")
  // At the cap, and an amountless invoice (it carries no amount to send): the wallet is asked.
  for (const inv of [sats(MAX_SEND_SATS), "lnbc1qqqqpzry9x8gf2"]) {
    assert.equal(sendCapRefusal(inv), "", inv)
    await assert.rejects(payInvoice(conn, inv, { connect }), /Couldn't reach your wallet's relay/)
  }
  assert.equal(asked, 2)
  // An LNURL service that takes up to 1 BTC: the range stops at the cap, and paying over it never fetches an invoice.
  const big = { callback: "https://zaps.example/cb", minMsat: 1000, maxMsat: 100_000_000_000, commentAllowed: 0, host: "zaps.example" }
  assert.deepEqual(checkAmount(big, MAX_SEND_SATS + 1), { tooLarge: true, minSats: 1, maxSats: MAX_SEND_SATS, capped: true })
  assert.equal(checkAmount(big, MAX_SEND_SATS).ok, true)
  const fetchImpl = async () => assert.fail("an invoice was fetched for an amount over the cap")
  await assert.rejects(payLnurl(conn, big, { sats: MAX_SEND_SATS + 1 }, { fetchImpl, pay: () => assert.fail("paid") }), /takes 1 to 10,000,000 sats/)
  // A service whose least is over the cap can't be paid at all.
  const tooRich = { ...big, minMsat: (MAX_SEND_SATS + 5) * 1000 }
  assert.equal(checkAmount(tooRich, MAX_SEND_SATS + 5).overCap, true)
  await assert.rejects(payLnurl(conn, tooRich, { sats: MAX_SEND_SATS + 5 }, { fetchImpl }), /only takes more than/)
})
