// The Relay tab shows the page's FIPS address with nostr-tools; it must be the npub the FIPS node itself reports.
import test from "node:test"
import assert from "node:assert/strict"
import { npubEncode } from "nostr-tools/nip19"
import { bytesToHex } from "nostr-tools/utils"
import { loadRelayIdentity } from "../../web-relay/src/fips/node.js"
import { encodeNpub } from "../../web-relay/node_modules/@fips/core/dist/index.js"

test("Relay tab address equals the FIPS node's npub, and is stable across loads", async () => {
  const items = new Map()
  const storage = { getItem: k => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) }
  const first = await loadRelayIdentity(storage)
  const shown = npubEncode(bytesToHex(first.xOnlyPubkey))
  assert.equal(shown, encodeNpub(first.xOnlyPubkey))
  assert.equal(npubEncode(bytesToHex((await loadRelayIdentity(storage)).xOnlyPubkey)), shown)
})
