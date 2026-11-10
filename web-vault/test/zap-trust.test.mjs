// Fix 8 on web: a kind 9735 is anyone's event, so it is believed only when the payee's own zap service published it
// and the request inside it verifies and names the same note. These are the runnable checks for the dashboard total,
// Popular's ranking and the wallet's receipt detail, plus the size cap on an LNURL reply. Throwaway keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { buildDashboard, fetchDashboard, WINDOW_S } from "../src/net/feed-dashboard.js"
import { tally, targetOf } from "../src/net/popular.js"
import { receiptOf } from "../src/net/wallet-zaps.js"
import { trustedReceipts, resolvePay, MAX_REPLY_BYTES } from "../src/net/zaps.js"

const key = () => { const sk = generateSecretKey(); return { sk, pk: getPublicKey(sk) } }
const hex = n => n.toString(16).padStart(64, "0")
const now = 1_762_300_000, since = now - WINDOW_S

// The payee's zap service: a lightning address whose LNURL names `nostrPubkey`, and nothing else is asked of it.
const lnurlService = pubkey => {
  const asked = []
  const fetchImpl = async u => {
    asked.push(u)
    return { ok: true, url: u, json: async () => ({ tag: "payRequest", callback: "https://zaps.example/cb", minSendable: 1000, maxSendable: 100_000_000, allowsNostr: true, nostrPubkey: pubkey }) }
  }
  return { asked, fetchImpl }
}

// A NIP-57 receipt: `sats` from its invoice, the request in `description`, signed by `publisher`.
const receipt = ({ payee, sender, note, sats = 1_000, publisher, at = now - 60 }) => finalizeEvent({
  kind: 9735, created_at: at, content: "",
  tags: [
    ["p", payee], ["e", note], ["bolt11", `lnbc${sats * 10}n1qqqq`],
    ["description", JSON.stringify(finalizeEvent({ kind: 9734, created_at: at, content: "", tags: [["p", payee], ["e", note]] }, sender))],
  ],
}, publisher)

test("dashboardSatsIgnoreAReceiptFromAnotherPublisher", async () => {
  const me = key(), service = key(), forger = key(), sender = key()
  const note = hex(3)
  const good = receipt({ payee: me.pk, sender: sender.sk, note, sats: 1_000, publisher: service.sk })
  const forged = receipt({ payee: me.pk, sender: sender.sk, note, sats: 5_000, publisher: forger.sk })
  // The dashboard's own fold counts whatever it is given: these two are 6,000 sats, which is the bug.
  assert.equal(buildDashboard({ zapReceipts: [good, forged], follows: new Set(), owner: me.pk, since, now }).satsReceived, 6_000)

  // The payee's LNURL names `service`; the fake host answers it, so nothing leaves the test.
  const { fetchImpl } = lnurlService(service.pk)
  const lnOf = async () => ({ lud16: "me@zaps.example" })
  const query = async (relays, f) => f.kinds?.includes(9735) ? [good, forged] : []
  const filtered = await fetchDashboard({
    follows: [sender.pk], owner: me.pk, readRelays: ["wss://relay.example"], blocked: new Set(), now, query,
    trust: evs => trustedReceipts(evs, lnOf, fetchImpl),
  })
  assert.equal(filtered.satsReceived, 1_000, "only the receipt the payee's own zap service published counts")

  // With no ctx and no trust injected, the request check still drops a receipt that has none: never fails open.
  const silent = { ...good, tags: good.tags.filter(t => t[0] !== "description") }
  const bare = await fetchDashboard({ follows: [sender.pk], owner: me.pk, readRelays: ["wss://r"], blocked: new Set(), now,
    query: async (r, f) => f.kinds?.includes(9735) ? [silent] : [] })
  assert.equal(bare.satsReceived, 0, "a receipt with no signed request inflates nothing")
})

test("popularWeightIgnoresARequestForAnotherNote", () => {
  const payee = key(), service = key(), sender = key()
  const A = hex(1), B = hex(2)
  const requestForA = finalizeEvent({ kind: 9734, created_at: now, content: "", tags: [["p", payee.pk], ["e", A]] }, sender.sk)
  // A real request for note A, wrapped in a fresh receipt whose `e` tag says note B.
  const wrapped = finalizeEvent({
    kind: 9735, created_at: now, content: "",
    tags: [["p", payee.pk], ["e", B], ["bolt11", "lnbc10u1p"], ["description", JSON.stringify(requestForA)]],
  }, service.sk)
  assert.equal(targetOf(wrapped), B, "the receipt names B")
  const trusted = new Set([sender.pk])
  const t = tally([wrapped], trusted)
  assert.equal(t.size, 0, "it scores nothing for B")

  // The same request in a receipt for the note it names still counts, so the rule is the note, not the shape.
  const honest = finalizeEvent({
    kind: 9735, created_at: now, content: "",
    tags: [["p", payee.pk], ["e", A], ["bolt11", "lnbc10u1p"], ["description", JSON.stringify(requestForA)]],
  }, service.sk)
  assert.deepEqual([...tally([honest], trusted).get(A)], [[sender.pk, 3]])
})

test("walletHistoryIgnoresAnUnsignedRequest", () => {
  const me = key(), service = key(), sender = key()
  const req = finalizeEvent({ kind: 9734, created_at: 1_000, content: "refund me at evil.example", tags: [["p", me.pk]] }, sender.sk)
  const withRequest = desc => finalizeEvent({ kind: 9735, created_at: 1_000, content: "", tags: [["p", me.pk], ["bolt11", "lnbc10u1pqqqq"], ["description", JSON.stringify(desc)]] }, service.sk)

  const good = receiptOf(withRequest(req))
  assert.equal(good?.detail.sender, sender.pk, "a signed request is read")
  assert.equal(good?.detail.comment, "refund me at evil.example")

  assert.equal(receiptOf(withRequest({ ...req, sig: "0".repeat(128) })), null, "a garbage signature yields no detail")
  assert.equal(receiptOf(withRequest({ ...req, pubkey: key().pk })), null, "so does another sender's key on a real sig")
})

test("an LNURL reply larger than the cap is refused, not buffered", async () => {
  const ln = { lud16: "bob@zaps.example" }
  // A declared length over the cap is refused before the body is read.
  await assert.rejects(
    resolvePay(ln, async u => new Response("{}", { headers: { "content-length": String(MAX_REPLY_BYTES + 1) } })),
    /too large to read/,
  )
  // A chunked body with no declared length is cut off the moment it passes the cap: only some of it is ever pulled.
  let pulled = 0
  const body = new ReadableStream({
    pull(c) { pulled++; c.enqueue(new Uint8Array(4_096)) }, // endless: a hostile host
  })
  const endless = new Response(body, { status: 200 })
  await assert.rejects(resolvePay(ln, async () => endless), /too large to read/)
  assert.ok(pulled <= Math.ceil(MAX_REPLY_BYTES / 4_096) + 2, `read ${pulled} chunks past the cap`)
  // An ordinary reply still parses.
  const ok = await resolvePay(ln, async u => new Response(JSON.stringify({ tag: "payRequest", callback: "https://zaps.example/cb" }), { status: 200 }))
  assert.equal(ok.callback, "https://zaps.example/cb")
})
