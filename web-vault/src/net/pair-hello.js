// The hello and ack of two-scan pairing on the web (docs/MESH_PAIRING_CONTRACT.md §3, plan §3): an ephemeral kind-21195
// event signed by this browser's mesh key (its FIPS key, never the account's), `p` = the other device's mesh pubkey,
// the content NIP-44 encrypted between the two mesh keys, sent to the finder relays. This is the only place the web
// reads its mesh key outside the FIPS engine (plan T2): per call, never kept, never logged, never handed to UI code,
// and it signs nothing but kind 21195 and the kind 22242 AUTH for this browser vault's own /files room (sealMeshAuth,
// Logen's go 2026-11-12: /files is read with a device's mesh key, never an account key). The session logic (who is
// accepted, what aborts) is mesh-pairing-session.js.
import { finalizeEvent, getPublicKey, verifyEvent } from "nostr-tools/pure"
import { makeAuthEvent } from "nostr-tools/nip42"
import * as nip44 from "nostr-tools/nip44"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { HELLO_KIND } from "./mesh-pairing.js"
import { FILES_AUTH_RELAY } from "./file-notes-live.js"
import { FINDER_RELAYS } from "../desktop/space/my-devices.js"
import { pool } from "./pool.js"
import { VAULT_NS, pageStorage } from "../../../web-relay/src/page-storage.js"

// web-relay/src/fips/node.js loadRelayIdentity, under VAULT_NS (haven/vault.js fipsStorage). Not imported from there:
// that module brings the whole FIPS engine into the vault's first load.
const KEY_ITEM = "fips-relay-key"
const HEX64 = /^[0-9a-f]{64}$/
const meshStorage = (storage = globalThis.localStorage) => pageStorage(storage, VAULT_NS)

/** This browser's mesh secret key, read for one call. Made first, as loadRelayIdentity does, when there is none; a
 *  stored key that isn't one is an error, never replaced (that would change this browser's address). */
async function meshKey(storage) {
  const s = meshStorage(storage)
  let hex = s.getItem(KEY_ITEM)
  if (!hex) {
    hex = bytesToHex(crypto.getRandomValues(new Uint8Array(32)))
    s.setItem(KEY_ITEM, hex)
  }
  if (!HEX64.test(hex)) throw new Error("this browser's mesh key can't be read")
  return hexToBytes(hex)
}

/** This browser's mesh address as x-only hex (what the QR's `m` encodes). */
export async function ownMeshHex(storage) {
  const sk = await meshKey(storage)
  try { return getPublicKey(sk) } finally { sk.fill(0) }
}

/** A signed kind-21195 event carrying `content` (hello or ack JSON) to `toHex`, encrypted to it. `sk` is for tests;
 *  without it the browser's mesh key is read for this call only. */
export async function sealHello({ toHex, content, now = Math.floor(Date.now() / 1000), storage, sk: given }) {
  if (!HEX64.test(toHex ?? "")) throw new Error("not a mesh address")
  const sk = given ?? await meshKey(storage)
  try {
    const key = nip44.v2.utils.getConversationKey(sk, toHex)
    return finalizeEvent({ kind: HELLO_KIND, created_at: now, tags: [["p", toHex]], content: nip44.v2.encrypt(content, key) }, sk)
  } finally { if (!given) sk.fill(0) }
}

/** The NIP-42 AUTH (kind 22242) for this browser vault's /files room (net/file-notes-live.js), signed by this browser's
 *  mesh key, which haven-go files_relay.go reads as the vault's own key. Its relay tag is fixed: it signs for no other
 *  room. `sk` is for tests. */
export async function sealMeshAuth({ challenge, storage, sk: given }) {
  if (typeof challenge !== "string" || !challenge) throw new Error("no AUTH challenge")
  const sk = given ?? await meshKey(storage)
  try {
    return finalizeEvent(makeAuthEvent(FILES_AUTH_RELAY, challenge), sk)
  } finally { if (!given) sk.fill(0) }
}

/** `{ sender, content }` from a kind-21195 event to this device, or null when it isn't one: wrong kind, not addressed
 *  to `ownHex`, a bad signature (checked on a fresh copy: verifyEvent trusts a flag the object may carry), or content
 *  that doesn't decrypt with the two mesh keys. The session decides the rest. */
export async function openHello(ev, { ownHex, storage, sk: given } = {}) {
  if (ev?.kind !== HELLO_KIND || !HEX64.test(ev.pubkey ?? "") || typeof ev.content !== "string") return null
  const p = (ev.tags ?? []).filter(t => Array.isArray(t) && t[0] === "p").map(t => t[1])
  if (p.length !== 1 || p[0] !== ownHex) return null
  const { id, pubkey, created_at, kind, tags, content, sig } = ev
  if (!verifyEvent({ id, pubkey, created_at, kind, tags, content, sig })) return null
  const sk = given ?? await meshKey(storage)
  try {
    return { sender: pubkey, content: nip44.v2.decrypt(content, nip44.v2.utils.getConversationKey(sk, pubkey)) }
  } catch { return null } finally { if (!given) sk.fill(0) }
}

/** Sends one sealed event to the finder relays. Resolves with how many took it (a resend is the same event, byte for
 *  byte, as the contract asks). */
export async function sendHello(ev, { relays = FINDER_RELAYS, publish = (r, e) => pool.publish(r, e) } = {}) {
  const results = await Promise.allSettled(publish(relays, ev))
  return results.filter(r => r.status === "fulfilled").length
}

/** Listens on the finder relays for kind-21195 events to `ownHex` from `since`; `onEvent(ev)` for each. -> close(). */
export function listenHellos(ownHex, onEvent, { relays = FINDER_RELAYS, since = Math.floor(Date.now() / 1000) - 30, subscribe = (r, f, h) => pool.subscribeMany(r, f, h) } = {}) {
  const seen = new Set()
  const sub = subscribe(relays, { kinds: [HELLO_KIND], "#p": [ownHex], since }, {
    onevent: ev => { if (ev?.id && !seen.has(ev.id)) { seen.add(ev.id); onEvent(ev) } },
  })
  return () => sub?.close?.()
}
