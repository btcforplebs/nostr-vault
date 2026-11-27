// NIP-30 custom emoji drawn as pictures (net/custom-emoji.js): in a note's text, a name, a reaction.
import { useEffect, useState } from "preact/hooks"
import { splitShortcodes, seenEmoji, onSeenEmoji } from "../net/custom-emoji.js"
import { clean } from "../net/clean-mode.js"

/** One emoji picture, sized to the text around it. */
export const EmojiImg = ({ code, url }) =>
  <img class="custom-emoji" src={url} alt={`:${code}:`} title={`:${code}:`} loading="lazy" referrerpolicy="no-referrer" draggable={false} />

/** `text` with each :shortcode: `map` has a picture for drawn as that picture. -> a string, or an array of nodes. */
export function emojiNodes(text, map, key = "e") {
  // Clean mode masks the words between pictures (net/clean-mode.js), never a shortcode.
  const parts = splitShortcodes(text, map)
  if (parts.length === 1) return clean(parts[0])
  return parts.map((s, i) => i % 2 === 0 ? clean(s) : <EmojiImg key={`${key}:${i}`} code={s} url={map.get(s)} />)
}

/** Re-renders when a reaction brings a new emoji picture. -> Map shortcode -> url */
export function useSeenEmoji() {
  const [, setTick] = useState(0)
  useEffect(() => onSeenEmoji(() => setTick(t => t + 1)), [])
  return seenEmoji()
}

/** A name (or any short text) with its custom emoji drawn; `map` from the profile's kind 0 emoji tags. */
export const EmojiText = ({ text, map }) => <>{emojiNodes(text, map)}</>

/** A reaction's emoji, or a summary of several ("🔥:blob:"): a :shortcode: with a known picture is drawn, unless
 *  `load` is false (a stranger's row: the picture would tell their server you looked), then it stays text. */
export function ReactionText({ text, load = true }) {
  const seen = useSeenEmoji()
  return <>{load ? emojiNodes(text, seen, "r") : text}</>
}
