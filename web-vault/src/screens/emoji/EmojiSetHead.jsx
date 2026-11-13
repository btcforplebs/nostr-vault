// A set's title line: its image, title, author and how many emoji, with how many are saved in your vault.
import { AuthorName } from "../../components/NoteCard.jsx"

export function EmojiSetHead({ set, savedCount = null, badge = null, onOpen }) {
  const body = (
    <>
      {set.image ? <img class="emoji-set-icon" src={set.image} alt="" loading="lazy" referrerpolicy="no-referrer" /> : <span class="emoji-set-icon" aria-hidden="true">☺</span>}
      <span class="emoji-set-text">
        <b>{set.title}</b>
        <span class="muted small">by <AuthorName pubkey={set.author} /> · {set.missing ? "not found on your relays" : `${set.emoji.length} emoji`}
          {savedCount !== null && !set.missing && <> · {savedCount ? `${savedCount} saved` : <span class="emoji-badge">Not saved</span>}</>}
          {badge && <> · <span class="emoji-badge">{badge}</span></>}</span>
      </span>
    </>
  )
  return onOpen ? <button type="button" class="emoji-set-head" onClick={onOpen}>{body}</button> : <div class="emoji-set-head">{body}</div>
}
