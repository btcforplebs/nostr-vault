// Zap the artist from Now Playing (the iPhone's ArtistZapPill): the same zap as a profile's Zap pill, to the person,
// not to a note. A tap zaps your default amount, a hold (or right-click) picks one, and the Zapping pill follows
// (ZapButton). Shown only once the artist's Nostr key is known and their profile has a lightning address.
import { useEffect, useState } from "preact/hooks"
import { ZapButton } from "../components/ZapButton.jsx"
import { useProfile } from "../components/useProfile.js"
import { actionContext } from "../net/actions.js"
import { fetchProfiles } from "../net/profiles.js"
import { artistKey } from "./wavlake.js"

export function ArtistZap({ track }) {
  const [hex, setHex] = useState(null)
  useEffect(() => {
    let live = true
    setHex(null)
    artistKey(track).then(k => {
      if (!live || !k) return
      setHex(k)
      const ctx = actionContext()
      if (ctx) fetchProfiles(ctx.vault, [k], ctx.account.relays.read, { save: false }).catch(() => {})
    })
    return () => { live = false }
  }, [track?.id])
  const profile = useProfile(hex)
  if (!hex || !(profile?.lud16 || profile?.lud06)) return null
  // In a .note-actions span for the notes' bolt capsule (note-actions.css, wallet.css).
  return <span class="note-actions artist-zap"><ZapButton pubkey={hex} /></span>
}
