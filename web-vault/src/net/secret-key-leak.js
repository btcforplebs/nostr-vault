// A secret key typed where it would be published (Logen 2026-11-20, key-leak guard; background
// RESEARCH/NV_PUBLIC_NSEC_ACCOUNTS_2026_11_20.md: 144 people pasted their nsec into a new account's name box).
//
// 1. Guard: nothing this browser signs or seals may carry a valid nsec. The signers (signer/local.js, nip07.js,
//    nip46.js) call assertNoSecretKey on every event before it is signed, and dms.js on a message before it is sealed;
//    the composers check first so the words stay in the box. No override.
// 2. Label: a kind 0 we already load (profiles.js store) that carries a valid nsec makes the key's own pubkey a
//    "public key" account: its profile says so and the web gate (web-gate.js, web-trust.js, dm-trust.js) treats it as
//    outside the web. No relay is asked for this.
//
// Only a checksum-valid bech32 "nsec" of exactly 32 bytes counts, never the prefix alone or a cut-off key. The key
// itself is never logged, stored or sent: only the pubkey it derives is kept, in memory. The Apple and Android apps
// have the same rule, in their own key-leak guard PRs.
import { bech32 } from "@scure/base"
import { getPublicKey } from "nostr-tools/pure"

/** What the composer says, word for word on every platform. */
export const SECRET_KEY_BLOCKED = "This is a secret key. Publishing it lets anyone post as you."
/** What a profile whose key is public says. */
export const PUBLIC_KEY_LABEL = "Key is public. Anyone can post as this account"

// "nsec1" and 58 bech32 characters (52 for 32 bytes, 6 checksum), either case; nostr:nsec1… matches inside.
const CANDIDATE = /nsec1[02-9ac-hj-np-z]{58}/gi

/** Each valid secret key in `text`, as bytes. The caller zeroes them. */
function keysIn(text) {
  const out = []
  if (typeof text !== "string" || text.length < 63) return out
  for (const m of text.matchAll(CANDIDATE)) {
    try {
      // Throws on a bad checksum or mixed case (BIP-173); fromWords throws on bad padding.
      const { prefix, words } = bech32.decode(m[0], 90)
      if (prefix.toLowerCase() !== "nsec") continue
      const bytes = bech32.fromWords(words)
      if (bytes.length === 32) out.push(Uint8Array.from(bytes))
      bytes.fill?.(0)
    } catch {}
  }
  return out
}

/** Whether `text` holds a valid nsec. */
export function containsSecretKey(text) {
  const keys = keysIn(text)
  for (const k of keys) k.fill(0)
  return keys.length > 0
}

// "nsec1" and the 52 characters that carry the 32 key bytes, the checksum cut off. The setup name box keeps 60
// characters, so a pasted nsec loses 3 checksum characters there and the key is still whole.
const KEY_BODY = /nsec1[02-9ac-hj-np-z]{52}/i

/** Whether `text` holds a whole key, checksum or not: for a box that cuts text short (CreateAccount's 60-character name). */
export const holdsSecretKey = text => containsSecretKey(text) || (typeof text === "string" && KEY_BODY.test(text))

/** The pubkeys (hex) of the valid nsecs in `text`. A key that isn't a valid secp256k1 scalar is skipped. */
export function derivedPubkeys(text) {
  const out = new Set()
  for (const k of keysIn(text)) {
    // 0 and the curve order (n) are no key: noble throws for them; an all-zero answer is skipped too, as the apps do.
    try { const pk = getPublicKey(k); if (!/^0{64}$/.test(pk)) out.add(pk) } catch {}
    k.fill(0)
  }
  return [...out]
}

/** The strings of an event that would be published: its content and every tag value. */
const eventTexts = ev => [ev?.content, ...(ev?.tags ?? []).flatMap(t => (Array.isArray(t) ? t : []))]

/** Whether an event (or template) carries a valid nsec anywhere it would be published. */
export const eventHasSecretKey = ev => eventTexts(ev).some(containsSecretKey)

/** The guard's error: our sentence (`fixed`, so the Messages screen shows it as it is). */
export const secretKeyError = () => Object.assign(new Error(SECRET_KEY_BLOCKED), { fixed: true, secretKey: true })

/** A repost (kind 6, 16 generic) carries someone else's signed event as its content: their words, not yours, and
 *  already public. Android and Apple let it through the same way. */
const REPOST_KINDS = new Set([6, 16])

/** Throws secretKeyError when the event carries a valid nsec. Every signer calls this before it signs. */
export function assertNoSecretKey(ev) {
  if (REPOST_KINDS.has(ev?.kind)) return
  if (eventHasSecretKey(ev)) throw secretKeyError()
}

// ---- Public-key accounts, from kind 0s already loaded ----

const publicKeys = new Set()
const listeners = new Set()

/** Whether `pk`'s secret key has been seen published in a profile. */
export const isPublicKeyAccount = pk => !!pk && publicKeys.has(String(pk).toLowerCase())
export function onPublicKeys(cb) { listeners.add(cb); return () => listeners.delete(cb) }

/** Read a kind 0 we already have: every valid nsec in it marks its pubkey as public. -> the newly marked pubkeys */
export function notePublicKeys(ev) {
  if (ev?.kind !== 0) return []
  const fresh = eventTexts(ev).flatMap(derivedPubkeys).filter(pk => !publicKeys.has(pk))
  for (const pk of fresh) publicKeys.add(pk)
  if (fresh.length) for (const cb of listeners) { try { cb(fresh) } catch {} }
  return fresh
}

/** For tests and sign-out. */
export function forgetPublicKeys() { publicKeys.clear() }
