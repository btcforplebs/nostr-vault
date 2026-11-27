// Muted words in messages (Logen 11-27): a conversation where the other person wrote a muted word is hidden as a whole
// row, from the Messages list, the desktop peek, the Messages napplet, the unread badge and message notifications,
// the way a blocked person's is. Only their messages count; your own words never hide a conversation. Opening the
// conversation directly (from their profile) still shows it. Matching is the notes' whole-word rule
// (web-gate.js hasMutedWord), run on the decrypted text.
import { hasMutedWord } from "./web-gate.js"

// message object -> { words, hit }: a message's text doesn't change once opened (an edit is a new object), so each is
// checked once per word list.
const seen = new WeakMap()
const hits = (m, words) => {
  const c = seen.get(m)
  if (c && c.words === words) return c.hit
  const hit = m.from === m.peer && hasMutedWord(m.content, words)
  seen.set(m, { words, hit })
  return hit
}

/** Peers whose messages to the user hold a muted word (`words`, muteEntries' list). -> Set */
export function mutedWordPeers(messages, words) {
  const out = new Set()
  if (!words?.length) return out
  for (const m of messages.values()) if (m && !out.has(m.peer) && hits(m, words)) out.add(m.peer)
  return out
}

/** `blocked` (a muteSet) plus the peers mutedWordPeers names, for screens that hide by peer. With no muted word in
 *  any message it is `blocked` itself. -> a Set */
export function dmHiddenPeers(messages, blocked) {
  const muted = mutedWordPeers(messages, blocked?.words)
  if (!muted.size) return blocked ?? new Set()
  return new Set([...(blocked ?? []), ...muted])
}
