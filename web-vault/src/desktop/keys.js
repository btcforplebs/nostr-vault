// Desktop shortcuts (design §3, choice C1): single keys, off while typing, so nothing the browser owns (⌘1–9, ⌘N,
// ⌘F, ⌘W) is taken. "g" then a letter goes to a screen. ⌘/Ctrl+Enter sends from a text field.

export const GO = { f: "feed", s: "search", p: "profile", w: "wot", v: "vault", m: "messages", ",": "settings" }

const SINGLE = {
  j: "next", k: "prev", Enter: "open", o: "open", Escape: "close", "/": "search",
  n: "compose", c: "compose", r: "reply", l: "like", z: "zap", "[": "foldSide", "]": "foldNote", "?": "help",
}

/** The list shown in the shortcuts sheet, in its order: [keys, what it does]. */
export const SHEET = [
  ["j / k", "Next / previous row"], ["Enter / o", "Open in the note column"], ["Esc", "Close a dialog, then the note"],
  ["/", "Search"], ["n / c", "New Post"], ["r", "Reply"], ["l", "Like"], ["z", "Zap"],
  ["g f · g s · g p", "Feed · Search · Profile"], ["g w · g v · g m · g ,", "WoT · Vault · Messages · Settings"],
  ["[", "Fold the sidebar"], ["]", "Fold the note column"], ["⌘/Ctrl Enter", "Send (compose and messages)"], ["?", "This list"],
]

/** One key press -> { cmd, arg? } | { pending: "g" } | null.
 *  `typing`: focus is in a text field. `pending`: "g" was pressed just before. */
export function keyCommand({ key, metaKey = false, ctrlKey = false, altKey = false, typing = false, pending = null }) {
  if ((metaKey || ctrlKey) && key === "Enter") return typing ? { cmd: "send" } : null
  if (metaKey || ctrlKey || altKey) return null
  if (key === "Escape") return { cmd: "close" }
  if (typing) return null
  if (pending === "g") return GO[key] ? { cmd: "go", arg: GO[key] } : null
  if (key === "g") return { pending: "g" }
  return SINGLE[key] ? { cmd: SINGLE[key] } : null
}
