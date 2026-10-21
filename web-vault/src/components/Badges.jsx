// After an author's name, as on the iPhone (FeedNoteRow+Layout, CondensedNoteLine): the verified seal when the profile
// carries a NIP-05, and the Nostr Vault badge on notes sent from Nostr Vault on any platform (its client tag).
import { useProfile } from "./useProfile.js"

if (import.meta.env) import("../styles/badges.css")

/** Sent from Nostr Vault: the client tag every Nostr Vault note carries ("Nostr Vault on iOS", "… on Android", …). */
export const fromNostrVault = note => (note?.tags ?? []).some(t => t[0] === "client" && String(t[1] ?? "").startsWith("Nostr Vault"))

export function Badges({ pubkey, note }) {
  const p = useProfile(pubkey)
  return <>
    {p?.nip05 && <span class="badge-seal" title={p.nip05.replace(/^_@/, "")} role="img" aria-label="Verified">
      <svg viewBox="0 0 24 24" width="1em" height="1em" aria-hidden="true"><path fill="currentColor" d="M12 1.5l2.6 1.9 3.2-.2 1 3.1 2.7 1.8-1 3.1 1 3.1-2.7 1.8-1 3.1-3.2-.2L12 22.5l-2.6-1.9-3.2.2-1-3.1-2.7-1.8 1-3.1-1-3.1 2.7-1.8 1-3.1 3.2.2z" /><path d="M8 12.2l2.6 2.6L16.2 9" fill="none" stroke="#000" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </span>}
    {fromNostrVault(note) && <span class="badge-nv" title="Sent from Nostr Vault" role="img" aria-label="Sent from Nostr Vault" />}
  </>
}
