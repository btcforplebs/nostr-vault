// Settings › Reactions › Default Reaction (iPhone AppearanceSettingsView): the emoji a one-tap like sends, picked from
// the same emoji sheet the like button's "+" opens.
import { useState } from "preact/hooks"
import { defaultReaction, setDefaultReaction } from "../net/reaction-pref.js"
import { EmojiPicker } from "./ReactionButton.jsx"

export function DefaultReactionRow() {
  const [emoji, setEmoji] = useState(() => defaultReaction())
  const [open, setOpen] = useState(false)
  const pick = e => { setDefaultReaction(e); setEmoji(defaultReaction()); setOpen(false) }
  return (
    <>
      <button type="button" class="settings-row static default-reaction" aria-haspopup="dialog" aria-label={`Default Reaction: ${emoji}. Change`} onClick={() => setOpen(true)}>
        <span class="settings-title">Default Reaction</span>
        <span class="default-reaction-emoji" aria-hidden="true">{emoji}</span>
        <svg class="settings-chevron" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 5l7 7-7 7" /></svg>
      </button>
      <p class="settings-note muted small">Sets which emoji is used for one-tap reactions.</p>
      {open && <EmojiPicker current={emoji} title="Default Reaction" action="Use" onPick={pick} onClose={() => setOpen(false)} />}
    </>
  )
}
