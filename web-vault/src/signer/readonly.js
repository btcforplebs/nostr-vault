// Read-only sign-in: an npub, a hex pubkey, an nprofile or a NIP-05 name, and no signer at all. The page reads your
// notes, follows and feed, and its relay (FIPS included) runs as usual; anything that needs a signature throws
// READ_ONLY, which every action already shows as its error.
import { decode } from "nostr-tools/nip19"
import { queryProfile } from "nostr-tools/nip05"
import { checkedPubkey } from "../session.js"

export const READ_ONLY = "You're signed in read-only. Sign in with an extension or a bunker to post, react, follow or open messages."

const HEX = /^[0-9a-f]{64}$/i

/** "npub1…", "nostr:npub1…", "nprofile1…", 64 hex, or "name@domain" / "domain" (NIP-05) -> 64 lowercase hex. */
export async function resolvePubkey(input, lookup = queryProfile) {
  const s = String(input ?? "").trim().replace(/^nostr:/i, "")
  if (!s) throw new Error("Type an npub or a NIP-05 name like you@example.com")
  if (HEX.test(s)) return s.toLowerCase()
  if (/^n(pub|profile)1/i.test(s)) {
    let d
    try { d = decode(s.toLowerCase()) } catch { throw new Error("That npub isn't valid. Check it was copied whole.") }
    if (d.type === "npub") return checkedPubkey(d.data)
    if (d.type === "nprofile") return checkedPubkey(d.data.pubkey)
  }
  if (/^nsec1/i.test(s)) throw new Error("That's a secret key. Never paste it here: use your npub instead.")
  if (/^([\w.+-]+@)?[\w-]+(\.[\w-]+)+$/.test(s)) {
    let p = null
    try { p = await lookup(s) } catch {}
    if (!p?.pubkey) throw new Error(`Couldn't find ${s}. Check the spelling, or use your npub.`)
    return checkedPubkey(p.pubkey)
  }
  throw new Error("That isn't an npub or a NIP-05 name.")
}

/** True when the box names one key (hex, npub, nprofile, nsec) or a NIP-05; anything else is a name to search for. */
export function namesAKey(input) {
  const s = String(input ?? "").trim().replace(/^nostr:/i, "")
  return HEX.test(s) || /^n(pub|profile|sec)1/i.test(s) || /^([\w.+-]+@)?[\w-]+(\.[\w-]+)+$/.test(s)
}

export async function readonlySignIn(input, lookup) {
  const pubkey = await resolvePubkey(input, lookup)
  return { signer: readonlySigner(), session: { method: "readonly", pubkey } }
}

/** No crypto: Messages and private block lists already say "this sign-in can't decrypt". */
export function readonlySigner() {
  return {
    method: "readonly",
    readOnly: true,
    signEvent: async () => { throw new Error(READ_ONLY) },
    close() {},
  }
}
