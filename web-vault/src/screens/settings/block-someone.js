// Block Someone's rule (screens/settings/BlockSomeone.jsx). No JSX, so tests can import it.
import { decode } from "nostr-tools/nip19"

/** npub / nprofile / 64-hex (with or without nostr:) -> hex key, else null. */
function keyOf(s) {
  if (/^[0-9a-f]{64}$/i.test(s)) return s.toLowerCase()
  try {
    const d = decode(s.replace(/^nostr:/, ""))
    if (d.type === "npub") return d.data
    if (d.type === "nprofile") return d.data.pubkey
  } catch {}
  return null
}

/** The key typed in, or null: not a key, or the user's own. */
export const blockTarget = (s, me) => { const pk = keyOf(String(s ?? "").trim()); return pk && pk !== me ? pk : null }
