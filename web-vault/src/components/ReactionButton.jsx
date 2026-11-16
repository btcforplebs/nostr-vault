// Like, as on the iPhone (FeedNoteRow+Reactions, ReactionTapback, EmojiPickerView): a tap reacts with ❤️ or takes the
// reaction back; a hold (or right-click) opens the tapback bar ❤️ 🤙 🔥 😂 😮 😢 and "+", which opens the emoji
// picker. Picking your current emoji takes it back, another swaps it (net/actions.js act). The button shows your
// emoji: a filled red heart for ❤️, the emoji itself otherwise.
import { useEffect, useRef, useState } from "preact/hooks"
import { act, actionState, reactionOf } from "../net/actions.js"
import { Dialog } from "./Moderation.jsx"
import { showToast } from "./Toast.jsx"
import { CATEGORIES, KEYWORDS } from "./emoji-data.js"
import { myEmoji, reactionCode, seenEmoji } from "../net/custom-emoji.js"
import { EmojiImg, ReactionText } from "./CustomEmoji.jsx"

export const TAPBACK = ["❤️", "🤙", "🔥", "😂", "😮", "😢"]
export const QUICK = ["❤️", "👍", "🔥", "😂", "😮", "😢", "🎉", "🚀"]
const HOLD_MS = 350
const HEART = "M12 20.5S3.5 15.3 3.5 9.2A4.7 4.7 0 0 1 12 6.4a4.7 4.7 0 0 1 8.5 2.8c0 6.1-8.5 11.3-8.5 11.3z"

/** How a reaction's content shows (reactionDisplayEmoji): "", +, +1 and hearts are ❤️, - is 👎, a :shortcode: with a
 *  known picture stays itself (drawn by ReactionText), else its first emoji. */
export function displayEmoji(content) {
  const c = String(content ?? "").trim()
  if (["", "+", "+1", "❤", "❤️"].includes(c)) return "❤️"
  if (c === "-") return "👎"
  const code = reactionCode(c)
  if (code && seenEmoji().has(code)) return c
  return firstEmoji(c) || "❤️"
}

/** The first character of `text` when it is an emoji, else "". */
export function firstEmoji(text) {
  const first = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(String(text ?? "").trim())][0]?.segment ?? ""
  return /\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(first) ? first : ""
}

/** The pill once a like has landed or failed (LikeFeedback): "Liked", "Reacted 🔥", or why it didn't go out. Nothing
 *  for an Unlike, which leaves no like behind. -> { message, tone, icon } | null */
export function likeFeedback(state, emoji) {
  if (state === "sent") {
    const shown = displayEmoji(emoji)
    return { message: shown === "❤️" ? "Liked" : `Reacted ${shown}`, tone: "accent", icon: "heart" }
  }
  if (state?.error && !state.unlike) {
    const why = /relay/i.test(state.error) ? "no relay took it" : /different account/i.test(state.error) ? "your signer signed as another account"
      : "your signer didn't answer"
    return { message: `Like failed: ${why}`, tone: "error", icon: "warn" }
  }
  return null
}

/** act() for the heart, with its pill once the like has landed or failed. */
export async function likeWithFeedback(ctx, note, emoji) {
  await act(ctx, "like", note, emoji)
  const f = likeFeedback(actionState(note.id).like, reactionOf(note.id))
  if (f) showToast({ key: "like", ...f })
}

/** What a pick asks act() for: your own reaction, as the button shows it, takes it back (no emoji = toggle), even when
 *  its stored content is "+" or "❤" or a shortcode; anything else reacts with that emoji. */
export const pickFor = (mine, emoji) => (mine && emoji === mine ? undefined : emoji)

export function ReactionButton({ ctx, note, state, off }) {
  const [bar, setBar] = useState(false)
  const [picker, setPicker] = useState(false)
  const hold = useRef(null), held = useRef(false), ref = useRef(null)
  useEffect(() => {
    if (!bar) return
    const away = e => { if (!ref.current?.contains(e.target)) setBar(false) }
    const esc = e => { if (e.key === "Escape") setBar(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", esc)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc) }
  }, [bar])
  // A like going out already shows as yours (net/actions.js like); only the unlike or a swap is "busy".
  const pending = state === "pending", sent = state === "sent" || pending, busy = state === "busy", error = state?.error
  const mine = sent ? displayEmoji(reactionOf(note.id)) : null
  const react = emoji => { setBar(false); setPicker(false); likeWithFeedback(ctx, note, pickFor(mine, emoji)) }
  const down = () => { held.current = false; hold.current = setTimeout(() => { held.current = true; setBar(true) }, HOLD_MS) }
  const up = () => clearTimeout(hold.current)
  const click = e => {
    e.stopPropagation()
    if (held.current) { held.current = false; return }
    if (!busy && !pending) likeWithFeedback(ctx, note)
  }
  const name = off ? `Like. ${off}` : error ? `${state.unlike ? "Unlike" : "Like"} didn't go out: ${error}. Try again`
    : busy ? "Like: sending" : mine ? `Your reaction: ${mine}. Tap to remove it, hold to change it` : "React. Hold for more reactions"
  const tapback = TAPBACK
  return (
    <span class="reaction" ref={ref} onClick={e => e.stopPropagation()}>
      <button type="button" class={`note-action like${sent ? " sent" : ""}${mine && mine !== "❤️" ? " emoji" : ""}${error ? " failed" : ""}${off ? " off" : ""}`}
        aria-label={name} title={name} aria-pressed={sent} aria-busy={busy || undefined} aria-disabled={busy || pending || !!off || undefined} aria-haspopup="menu" aria-expanded={bar}
        onPointerDown={off || pending ? undefined : down} onPointerUp={up} onPointerLeave={up} onClick={off ? undefined : click}
        onContextMenu={e => { e.preventDefault(); up(); if (!off && !busy && !pending) setBar(true) }}>
        {mine && mine !== "❤️" ? <span class="reaction-emoji"><ReactionText text={mine} /></span>
          : <svg viewBox="0 0 24 24" width="16" height="16" fill={sent ? "currentColor" : "none"} stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={HEART} /></svg>}
      </button>
      {bar && (
        <div class="tapback" role="menu" aria-label="Reactions">
          {tapback.map(e => <button key={e} type="button" role="menuitem" class={e === mine ? "on" : ""} aria-label={e === mine ? `${e}, your reaction` : e} onClick={() => react(e)}>{e}</button>)}
          <button type="button" role="menuitem" class="tapback-more" aria-label="More reactions" onClick={() => { setBar(false); setPicker(true) }}>+</button>
        </div>
      )}
      {picker && <EmojiPicker ctx={ctx} current={mine} onPick={react} onClose={() => setPicker(false)} />}
    </span>
  )
}

/** Search: an emoji matches its category's name, its keywords, or itself. */
export function matches(e, category, q) {
  const s = String(q ?? "").trim().toLowerCase()
  return !s || e === s || category.toLowerCase().includes(s) || (KEYWORDS[e] ?? "").split(" ").some(w => w.startsWith(s))
}

/** Your emoji (NIP-30, the sets your emoji list names) for the picker, once they load. `ctx` null: none. */
function useMyEmoji(ctx) {
  const [list, setList] = useState([])
  const me = ctx?.session?.pubkey
  useEffect(() => {
    let live = true
    if (me) myEmoji(ctx).then(l => live && setList(l))
    return () => { live = false }
  }, [me])
  return list
}

/** Search: a custom emoji matches its shortcode or its set's name. */
export const matchesCustom = (e, q) => { const s = String(q ?? "").trim().toLowerCase().replace(/^:|:$/g, ""); return !s || e.code.toLowerCase().includes(s) || (e.set ?? "").toLowerCase().includes(s) }

/** The picker sheet; Settings › Default Reaction opens it too, with its own `title` and `action`. With `ctx`, your
 *  custom emoji come first; a pick of one is onPick(":code:", { code, url }). */
export function EmojiPicker({ ctx = null, current, onPick, onClose, title = "React with Emoji", action = "React" }) {
  const [custom, setCustom] = useState("")
  const [q, setQ] = useState("")
  const mine = useMyEmoji(ctx).filter(e => matchesCustom(e, q))
  const first = firstEmoji(custom)
  const okCustom = !!first
  const groups = CATEGORIES.map(([name, list]) => [name, list.split(" ").filter(e => matches(e, name, q))]).filter(([, l]) => l.length)
  const cell = e => <button key={e} type="button" class={`picker-cell${e === current ? " on" : ""}`} aria-label={e === current ? `${e}, your reaction` : e} onClick={() => onPick(e)}>{e}</button>
  return (
    <Dialog label={title} onClose={onClose}>
      <div class="info-head"><h3>{title}</h3><button type="button" class="small" onClick={onClose}>Done</button></div>
      <h4 class="info-section">Quick Reactions</h4>
      <div class="picker-grid">{QUICK.map(cell)}</div>
      <h4 class="info-section">React with Custom Emoji</h4>
      <form class="picker-custom" onSubmit={e => { e.preventDefault(); if (okCustom) onPick(first) }}>
        <input value={custom} onInput={e => setCustom(e.currentTarget.value)} placeholder="Paste or type any emoji..." aria-label="Custom emoji" />
        <button type="submit" class="primary small" disabled={!okCustom}>{action}</button>
      </form>
      <input type="search" class="picker-search" value={q} onInput={e => setQ(e.currentTarget.value)} placeholder="Search emojis..." aria-label="Search emojis" />
      <div class="picker-scroll">
        {mine.length > 0 && <section><h4 class="info-section">Your Emoji</h4><div class="picker-grid">{mine.map(e => {
          const text = `:${e.code}:`, on = text === current
          return <button key={e.code} type="button" class={`picker-cell custom${on ? " on" : ""}`} aria-label={on ? `${text}, your reaction` : text} title={text} onClick={() => onPick(text, e)}><EmojiImg code={e.code} url={e.url} /></button>
        })}</div></section>}
        {groups.length ? groups.map(([name, list]) => <section key={name}><h4 class="info-section">{name}</h4><div class="picker-grid">{list.map(cell)}</div></section>)
          : !mine.length && <p class="muted small">No matching emojis found</p>}
      </div>
    </Dialog>
  )
}
