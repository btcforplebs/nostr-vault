// One emoji set: every emoji, Add to / Remove from your emoji list (kind 10030), and its link to share. Adding also
// sends the author's own signed set to your relays and keeps it in this browser's vault (net/emoji-sets.js keepSet).
import { useState } from "preact/hooks"
import { EmojiGrid } from "./EmojiGrid.jsx"
import { EmojiSetHead } from "./EmojiSetHead.jsx"
import { setLink } from "../../net/emoji-sets.js"

export function EmojiSetDetail({ set, inList, canEdit, links, saved, onChange, onBack, readOnly }) {
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState("")
  const toggle = async () => {
    setBusy(true); setNote("")
    setNote(await onChange(set, !inList))
    setBusy(false)
  }
  const copyLink = () => navigator.clipboard?.writeText(`nostr:${setLink(set)}`).then(() => setNote("Link copied."), () => setNote("Couldn't copy the link."))
  return (
    <section class="emoji-detail">
      <button type="button" class="small" onClick={onBack}>‹ Back</button>
      <EmojiSetHead set={set} />
      {set.description && <p class="muted small">{set.description}</p>}
      <div class="emoji-actions">
        {!set.missing && <button type="button" class={inList ? "" : "primary"} disabled={busy || !canEdit || readOnly} onClick={toggle}>
          {busy ? "Saving…" : inList ? "Remove from my emoji" : "Add to my emoji"}</button>}
        {!set.missing && <button type="button" class="small" onClick={copyLink}>Copy link</button>}
      </div>
      {readOnly ? <p class="status-line muted small">Signed in read-only: adding or removing a set needs your key.</p>
        : !canEdit && <p class="status-line muted small">Your relays haven't answered yet, so your emoji list can't be changed safely.</p>}
      {note && <p class="status-line" role="status">{note}</p>}
      <EmojiGrid set={set} links={links} saved={saved} />
    </section>
  )
}
