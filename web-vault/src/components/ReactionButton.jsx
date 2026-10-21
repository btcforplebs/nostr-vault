// Like, as on the iPhone (FeedNoteRow+Reactions, ReactionTapback, EmojiPickerView): a tap reacts with ❤️ or takes the
// reaction back; a hold (or right-click) opens the tapback bar ❤️ 🤙 🔥 😂 😮 😢 and "+", which opens the emoji
// picker. Picking your current emoji takes it back, another swaps it (net/actions.js act). The button shows your
// emoji: a filled red heart for ❤️, the emoji itself otherwise.
import { useEffect, useRef, useState } from "preact/hooks"
import { act, reactionOf } from "../net/actions.js"
import { Dialog } from "./Moderation.jsx"

export const TAPBACK = ["❤️", "🤙", "🔥", "😂", "😮", "😢"]
export const QUICK = ["❤️", "👍", "🔥", "😂", "😮", "😢", "🎉", "🚀"]
const HOLD_MS = 350
const HEART = "M12 20.5S3.5 15.3 3.5 9.2A4.7 4.7 0 0 1 12 6.4a4.7 4.7 0 0 1 8.5 2.8c0 6.1-8.5 11.3-8.5 11.3z"

/** How a reaction's content shows (reactionDisplayEmoji): "", +, +1 and hearts are ❤️, - is 👎, else its first emoji. */
export function displayEmoji(content) {
  const c = String(content ?? "").trim()
  if (["", "+", "+1", "❤", "❤️"].includes(c)) return "❤️"
  if (c === "-") return "👎"
  return firstEmoji(c) || "❤️"
}

/** The first character of `text` when it is an emoji, else "". */
export function firstEmoji(text) {
  const first = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(String(text ?? "").trim())][0]?.segment ?? ""
  return /\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(first) ? first : ""
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
  const sent = state === "sent", busy = state === "busy", error = state?.error
  const mine = sent ? displayEmoji(reactionOf(note.id)) : null
  const react = emoji => { setBar(false); setPicker(false); act(ctx, "like", note, pickFor(mine, emoji)) }
  const down = () => { held.current = false; hold.current = setTimeout(() => { held.current = true; setBar(true) }, HOLD_MS) }
  const up = () => clearTimeout(hold.current)
  const click = e => {
    e.stopPropagation()
    if (held.current) { held.current = false; return }
    if (!busy) act(ctx, "like", note)
  }
  const name = off ? `Like. ${off}` : error ? `${state.unlike ? "Unlike" : "Like"} didn't go out: ${error}. Try again`
    : busy ? "Like: sending" : mine ? `Your reaction: ${mine}. Tap to remove it, hold to change it` : "React. Hold for more reactions"
  const tapback = TAPBACK
  return (
    <span class="reaction" ref={ref} onClick={e => e.stopPropagation()}>
      <button type="button" class={`note-action like${sent ? " sent" : ""}${mine && mine !== "❤️" ? " emoji" : ""}${error ? " failed" : ""}${off ? " off" : ""}`}
        aria-label={name} title={name} aria-pressed={sent} aria-busy={busy || undefined} aria-disabled={busy || !!off || undefined} aria-haspopup="menu" aria-expanded={bar}
        onPointerDown={off ? undefined : down} onPointerUp={up} onPointerLeave={up} onClick={off ? undefined : click}
        onContextMenu={e => { e.preventDefault(); up(); if (!off && !busy) setBar(true) }}>
        {mine && mine !== "❤️" ? <span class="reaction-emoji">{mine}</span>
          : <svg viewBox="0 0 24 24" width="16" height="16" fill={sent ? "currentColor" : "none"} stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={HEART} /></svg>}
      </button>
      {bar && (
        <div class="tapback" role="menu" aria-label="Reactions">
          {tapback.map(e => <button key={e} type="button" role="menuitem" class={e === mine ? "on" : ""} aria-label={e === mine ? `${e}, your reaction` : e} onClick={() => react(e)}>{e}</button>)}
          <button type="button" role="menuitem" class="tapback-more" aria-label="More reactions" onClick={() => { setBar(false); setPicker(true) }}>+</button>
        </div>
      )}
      {picker && <EmojiPicker current={mine} onPick={react} onClose={() => setPicker(false)} />}
    </span>
  )
}

const CATEGORIES = [
  ["Smileys", "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 😉 😊 😇 🥰 😍 🤩 😘 😋 😛 😜 🤪 🤔 🤨 😐 😑 😶 🙄 😏 😬 😌 😔 😴 😷 🤒 🤯 🥳 😎 🤓 🧐 😕 😟 🙁 😮 😲 😳 🥺 😢 😭 😱 😤 😡 🤬 💀 🤡 👻 👽 🤖 💩"],
  ["Hearts & Hands", "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 💯 💕 💖 💗 👍 👎 👌 🤌 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👋 🤚 ✋ 🖖 👏 🙌 🫶 👐 🤲 🤝 🙏 💪 🫡"],
  ["Fun & Activities", "🎉 🎊 🎁 🎈 ✨ 🔥 ⚡ 🌟 ⭐ 💫 🚀 🏆 🥇 🎯 🎮 🎲 🎵 🎶 🎸 🎤 🍕 🍔 🍟 🌮 🍣 🍩 🍪 🎂 🍺 🍻 🥂 🍷 ☕ 🧡 🫂 👀 🧠 💡 💰 ₿"],
  ["Animals & Nature", "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🦅 🦉 🐺 🐴 🦄 🐝 🦋 🐢 🐍 🐙 🦀 🐬 🐳 🌸 🌻 🌹 🌲 🌵 🍀 🍁 🌈 ☀️ 🌙 ❄️ 🌊"],
]

// Words each emoji answers to in Search, as well as its category's name.
const KEYWORDS = {
  "😀": "smile happy grin", "😂": "laugh lol joy tears", "🤣": "laugh rofl lol", "😊": "smile blush happy", "😍": "love heart eyes",
  "🥰": "love hearts", "😘": "kiss", "😎": "cool sunglasses", "🤔": "think hmm", "🙄": "eyeroll", "😴": "sleep tired",
  "🤯": "mind blown wow", "🥳": "party celebrate", "😮": "wow surprised oh", "😲": "shocked wow", "😳": "flushed embarrassed",
  "🥺": "please pleading", "😢": "sad cry tear", "😭": "cry sob sad", "😱": "scream scared", "😡": "angry mad", "🤬": "angry swear",
  "💀": "dead skull dying", "🤡": "clown", "👻": "ghost", "💩": "poop", "❤️": "heart love red", "🧡": "heart orange bitcoin",
  "💔": "broken heart", "💯": "hundred perfect", "👍": "thumbs up yes like ok", "👎": "thumbs down no dislike", "👌": "ok perfect",
  "🤙": "shaka call hang loose", "👋": "wave hello hi bye", "👏": "clap applause", "🙌": "hands raise praise", "🫶": "heart hands love",
  "🤝": "handshake deal", "🙏": "pray please thanks", "💪": "strong muscle flex", "🫡": "salute", "🎉": "party tada celebrate",
  "✨": "sparkles magic", "🔥": "fire hot lit", "⚡": "lightning zap bolt", "🌟": "star", "⭐": "star", "🚀": "rocket moon launch",
  "🏆": "trophy win", "🎯": "target bullseye", "🎵": "music note", "🍕": "pizza", "🍺": "beer", "☕": "coffee", "👀": "eyes look",
  "🧠": "brain smart", "💡": "idea bulb", "💰": "money bag", "₿": "bitcoin btc", "🐶": "dog puppy", "🐱": "cat kitty",
  "🦄": "unicorn", "🐝": "bee", "🌈": "rainbow", "☀️": "sun", "🌙": "moon night", "🌊": "wave ocean sea",
}
/** Search: an emoji matches its category's name, its keywords, or itself. */
export function matches(e, category, q) {
  const s = String(q ?? "").trim().toLowerCase()
  return !s || e === s || category.toLowerCase().includes(s) || (KEYWORDS[e] ?? "").split(" ").some(w => w.startsWith(s))
}

function EmojiPicker({ current, onPick, onClose }) {
  const [custom, setCustom] = useState("")
  const [q, setQ] = useState("")
  const first = firstEmoji(custom)
  const okCustom = !!first
  const groups = CATEGORIES.map(([name, list]) => [name, list.split(" ").filter(e => matches(e, name, q))]).filter(([, l]) => l.length)
  const cell = e => <button key={e} type="button" class={`picker-cell${e === current ? " on" : ""}`} aria-label={e === current ? `${e}, your reaction` : e} onClick={() => onPick(e)}>{e}</button>
  return (
    <Dialog label="React with Emoji" onClose={onClose}>
      <div class="info-head"><h3>React with Emoji</h3><button type="button" class="small" onClick={onClose}>Done</button></div>
      <h4 class="info-section">Quick Reactions</h4>
      <div class="picker-grid">{QUICK.map(cell)}</div>
      <h4 class="info-section">React with Custom Emoji</h4>
      <form class="picker-custom" onSubmit={e => { e.preventDefault(); if (okCustom) onPick(first) }}>
        <input value={custom} onInput={e => setCustom(e.currentTarget.value)} placeholder="Paste or type any emoji..." aria-label="Custom emoji" />
        <button type="submit" class="primary small" disabled={!okCustom}>React</button>
      </form>
      <input type="search" class="picker-search" value={q} onInput={e => setQ(e.currentTarget.value)} placeholder="Search emojis..." aria-label="Search emojis" />
      <div class="picker-scroll">
        {groups.length ? groups.map(([name, list]) => <section key={name}><h4 class="info-section">{name}</h4><div class="picker-grid">{list.map(cell)}</div></section>)
          : <p class="muted small">No matching emojis found</p>}
      </div>
    </Dialog>
  )
}
