// Messages perf review 2026-11-28 #7: with an extension or a key in this browser, a first load opens a real inbox
// whole (it stopped at 200, so chats showed part of their history); a bunker keeps its low ceiling. Throwaway keys,
// a fake /chat and a stubbed network: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import { rumorFor, wrapFor, loadMessages, getMessages, resetMessages, OPEN_LIMIT, openLimit } from "../src/net/dms.js"

const A = generateSecretKey(), B = generateSecretKey()
const pk = sk => getPublicKey(sk)
const cryptoOf = sk => ({
  encrypt: async (peer, t) => nip44.encrypt(t, nip44.getConversationKey(sk, peer)),
  decrypt: async (peer, c) => nip44.decrypt(c, nip44.getConversationKey(sk, peer)),
})
const envOf = sk => ({ signer: { signEvent: async t => finalizeEvent(t, sk) }, crypto: cryptoOf(sk), me: pk(sk) })

test("the non-bunker ceiling opens a few hundred messages in one load; a bunker's stays low", async () => {
  assert.ok(OPEN_LIMIT.other >= 1000)
  assert.equal(openLimit({ method: "nip07" }), OPEN_LIMIT.other)
  assert.equal(openLimit({ method: "local" }), OPEN_LIMIT.other)
  assert.equal(openLimit({ method: "nip46" }), OPEN_LIMIT.nip46)
  assert.ok(OPEN_LIMIT.nip46 <= 40)

  const wraps = []
  for (let i = 0; i < 250; i++) wraps.push(await wrapFor(rumorFor(pk(B), pk(A), `m${i}`, 1000 + i), envOf(B), pk(A)))
  resetMessages(pk(A))
  const chat = { query: async () => [], event: async () => ({ ok: true, message: "" }) }
  const query = async (r, f) => (f.kinds[0] === 1059 ? wraps : [])
  await loadMessages({ vault: {}, session: { method: "nip07", pubkey: pk(A) }, signer: envOf(A).signer, account: { relays: { read: [], write: [] } } },
    ["wss://r.example"], { crypto: cryptoOf(A), query, chat, cache: false })
  assert.equal(getMessages().messages.size, 250, "all 250 open, none left for Open more")
  assert.equal(getMessages().more, 0)
})
