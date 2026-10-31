// Share a profile, as the iPhone's ShareProfileSheet: a QR of the person's nostrvault.app/p/<npub> page (it opens on
// any device without an app), the link itself, Copy link, and the system share sheet where the browser has one.
// Shown as a button beside Edit Profile on your own profile and beside the ••• on anyone else's.
import { useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Dialog } from "./Moderation.jsx"
import { QrCode } from "../screens/WalletReceive.jsx"
import { useProfile } from "./useProfile.js"

/** The page a profile is shared as. */
export const profileLink = pubkey => `https://nostrvault.app/p/${npubEncode(pubkey)}`

const SHARE = "M4 12v7a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7M16 6l-4-4-4 4M12 2v13"

export function ShareProfileButton({ pubkey, className = "more-btn", own = false }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button type="button" class={className} aria-label={own ? "Share your profile" : "Share profile"} title="Share profile" onClick={() => setOpen(true)}>
        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={SHARE} /></svg>
      </button>
      {open && <ShareProfileSheet pubkey={pubkey} own={own} onClose={() => setOpen(false)} />}
    </>
  )
}

export function ShareProfileSheet({ pubkey, own, onClose }) {
  const p = useProfile(pubkey)
  const name = p?.display_name || p?.name || ""
  const link = profileLink(pubkey)
  const [note, setNote] = useState("")
  const copy = async () => {
    try { await navigator.clipboard.writeText(link); setNote("copied"); setTimeout(() => setNote(""), 2000) } catch { setNote("Couldn't copy: select the link above instead.") }
  }
  const canShare = typeof navigator.share === "function"
  const share = async () => { try { await navigator.share({ title: name ? `${name} on Nostr` : "On Nostr", url: link }) } catch {} }
  return (
    <Dialog label={own ? "Share your profile" : `Share ${name || "profile"}`} onClose={onClose}>
      <div class="share-profile">
        <h3>{own ? "Share your profile" : name ? `Share ${name}` : "Share profile"}</h3>
        <QrCode text={link} label={`QR code for ${name || "this profile"}'s profile page`} size={220} />
        <p class="share-link mono small">{link}</p>
        <div class="share-actions">
          <button type="button" class="primary" onClick={copy} aria-live="polite">{note === "copied" ? "✓ Copied" : "Copy link"}</button>
          {canShare && <button type="button" onClick={share}>Share…</button>}
          <button type="button" onClick={onClose}>Done</button>
        </div>
        {note && note !== "copied" && <p class="small muted" role="status">{note}</p>}
      </div>
    </Dialog>
  )
}
