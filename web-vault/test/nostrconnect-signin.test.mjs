// Sign in by scanning (nostrconnect://, signer/nip46.js) and the bunker link box: Amber couldn't get in on the box's
// "Bring an account" page, which had no code to scan (Logen, 2026-11-23).
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { getConversationKey, encrypt } from "nostr-tools/nip44"
import { parseBunkerInput } from "nostr-tools/nip46"
import { nostrConnectRequest, nostrConnectAnswer, nostrConnectSignIn, cleanBunkerInput, NOSTRCONNECT_RELAYS } from "../src/signer/nip46.js"

// What Amber's own parser reads (common/NostrConnectUri.kt): the raw query split on "&", each value split on its
// first "=" and form-decoded once.
function amberParse(uri) {
  const data = uri.replace(/^nostrconnect:\/\//, "")
  const out = { client: data.split("?")[0], relays: [], fields: {} }
  for (const p of data.slice(data.indexOf("?") + 1).split("&")) {
    const i = p.indexOf("="), k = p.slice(0, i), v = decodeURIComponent(p.slice(i + 1).replace(/\+/g, " "))
    if (k === "relay") out.relays.push(v); else out.fields[k] = v
  }
  return out
}

test("the QR code's URI is what Amber reads: our key, relays, secret, perms and name", () => {
  const sk = generateSecretKey()
  const req = nostrConnectRequest({ sk, secret: "0123abcd" })
  assert.match(req.uri, /^nostrconnect:\/\/[0-9a-f]{64}\?/)
  const a = amberParse(req.uri)
  assert.equal(a.client, getPublicKey(sk))
  assert.deepEqual(a.relays, NOSTRCONNECT_RELAYS)
  assert.equal(a.fields.secret, "0123abcd")
  assert.equal(a.fields.name, "Nostr Vault")
  assert.equal(a.fields.perms, "sign_event,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt")
  assert.ok(!req.uri.includes("+"), "no '+' a decoder could read as a space")
  // A real URL parser reads the same.
  const u = new URL(req.uri)
  assert.deepEqual(u.searchParams.getAll("relay"), NOSTRCONNECT_RELAYS)
  assert.equal(u.searchParams.get("secret"), "0123abcd")
})

test("each request has its own client key and secret", () => {
  const a = nostrConnectRequest(), b = nostrConnectRequest()
  assert.notEqual(a.clientPubkey, b.clientPubkey)
  assert.notEqual(a.secret, b.secret)
  assert.match(a.secret, /^[0-9a-f]{32}$/)
})

const answerFrom = (signerSk, req, payload, tags = [["p", req.clientPubkey]]) => finalizeEvent({
  kind: 24133, created_at: Math.floor(Date.now() / 1000), tags,
  content: encrypt(JSON.stringify(payload), getConversationKey(signerSk, req.clientPubkey)),
}, signerSk)

test("only an answer echoing the secret signs in, from the key that sent it", () => {
  const req = nostrConnectRequest(), signer = generateSecretKey()
  assert.equal(nostrConnectAnswer(answerFrom(signer, req, { id: "x", result: req.secret }), req), getPublicKey(signer))
  // Clave's multi-account form.
  assert.equal(nostrConnectAnswer(answerFrom(signer, req, { id: "x", result: JSON.stringify({ echoed_secret: req.secret }) }), req), getPublicKey(signer))
  // Anyone can publish a 24133 tagged to us: "ack", a wrong secret, an error, another client's tag, another kind.
  assert.equal(nostrConnectAnswer(answerFrom(signer, req, { id: "x", result: "ack" }), req), "")
  assert.equal(nostrConnectAnswer(answerFrom(signer, req, { id: "x", result: "nope" }), req), "")
  assert.equal(nostrConnectAnswer(answerFrom(signer, req, { id: "x", result: req.secret, error: "denied" }), req), "")
  assert.equal(nostrConnectAnswer(answerFrom(signer, req, { id: "x", result: req.secret }, [["p", "b".repeat(64)]]), req), "")
  assert.equal(nostrConnectAnswer({ ...answerFrom(signer, req, { id: "x", result: req.secret }), kind: 1 }, req), "")
  // Encrypted for another client key: can't be opened, so not an answer.
  const other = nostrConnectRequest()
  assert.equal(nostrConnectAnswer(answerFrom(signer, other, { id: "x", result: req.secret }, [["p", req.clientPubkey]]), req), "")
})

// A pool that hands the subscription's onevent to the test, and a signer that answers get_public_key.
function fakePool() {
  const subs = []
  return {
    subs, kept: [],
    keepForSigner(r) { this.kept.push(...r) },
    subscribe(relays, filter, params) { const s = { relays, filter, params, closed: false, close() { this.closed = true } }; subs.push(s); return s },
    publish: () => [Promise.resolve()],
  }
}

test("waiting: the right relays and filter, cancel closes it, a wrong answer doesn't end it", async () => {
  const pool = fakePool(), req = nostrConnectRequest()
  const w = nostrConnectSignIn(req, pool, { ms: 60_000 })
  assert.deepEqual(pool.kept, NOSTRCONNECT_RELAYS)
  const [sub] = pool.subs
  assert.deepEqual(sub.relays, NOSTRCONNECT_RELAYS)
  assert.deepEqual(sub.filter, { kinds: [24133], "#p": [req.clientPubkey], since: req.since })
  sub.params.onevent(answerFrom(generateSecretKey(), req, { id: "x", result: "ack" }))
  assert.equal(sub.closed, false)
  w.cancel()
  await assert.rejects(w.done, e => e.cancelled === true)
  assert.equal(sub.closed, true)
})

test("an unanswered code expires", async () => {
  const pool = fakePool()
  const w = nostrConnectSignIn(nostrConnectRequest(), pool, { ms: 20 })
  await assert.rejects(w.done, e => e.expired === true && /expired/.test(e.message))
  assert.equal(pool.subs[0].closed, true)
})

test("a pasted bunker link is cleaned up before it is read", async () => {
  const pk = "c".repeat(64), link = `bunker://${pk}?relay=wss://relay.nip46.com/&secret=1b4e28ba-2fa1-11d2-883f-0016d3cca427`
  for (const pasted of [link, ` ${link}\n`, `​${link}`, `nostr:${link}`, `Here is my bunker: ${link}`,
    link.replace("relay=", "relay=\n"), link.replace(pk, pk.toUpperCase()), link.replace("bunker://", "BUNKER://")]) {
    const bp = await parseBunkerInput(cleanBunkerInput(pasted))
    assert.ok(bp, JSON.stringify(pasted))
    assert.equal(bp.pubkey, pk)
    assert.deepEqual(bp.relays, ["wss://relay.nip46.com/"])
    assert.equal(bp.secret, "1b4e28ba-2fa1-11d2-883f-0016d3cca427")
  }
  // Without cleaning, nostr-tools refused these (the control: proves the cleaning is what makes them work).
  assert.equal(await parseBunkerInput(` ${link}\n`), null)
  assert.equal(await parseBunkerInput(link.replace(pk, pk.toUpperCase())), null)
  // A name@domain stays as it is.
  assert.equal(cleanBunkerInput(" alice@nsec.app "), "alice@nsec.app")
})
