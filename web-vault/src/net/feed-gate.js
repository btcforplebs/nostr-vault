// The feeds on the one web-of-trust gate (web-gate.js; RESEARCH/NV_ONE_WOT_GATE.md 2b, step 2): every note a feed
// draws is judged once, here. Inside notes show; hop-3 notes show rationed (capHop3); outside notes go to the feed's
// folded "Outside your web" section; blocked notes are hidden. The feed checks no web, block or mute list of its own.
// Each feed has a Reach setting (Settings › Feed › Reach), kept in this browser: "Your web" or "Your web + a few one
// hop out". A Global-style feed with the shield on Everyone reaches everyone (blocks still apply), and a list feed is
// a list you picked, so it is never judged by the web either. iPhone/Mac twin: FeedReach in FeedFilterEngine.
import { judgeNote, capHop3, VERDICTS } from "./web-gate.js"
import { globalLike } from "./feeds.js"

/** The feeds with a Reach setting, in the picker's order: the FeedScreen modes the gate judges. */
export const REACH_FEEDS = [
  ["following", "Following"], ["discovery", "Discover"], ["global", "Global"], ["hashtag", "Hashtags"],
  ["popular", "Popular"], ["media", "Media"], ["relay", "Relay feeds"],
]
/** Default reach per feed (spec 2b): your web everywhere. Underrated (web + hop 3) has no web feed yet. */
export const DEFAULT_REACH = Object.freeze({ underrated: "webAndHop3" })
export const REACH_LABELS = { web: "Your web", webAndHop3: "Your web + a few one hop out" }
const KEY = "nv-feed-reach"

const read = storage => { try { const v = JSON.parse(storage?.getItem(KEY) ?? "{}"); return v && typeof v === "object" ? v : {} } catch { return {} } }
/** A feed's chosen reach: "web" | "webAndHop3". */
export const loadReach = (feed, storage = globalThis.localStorage) => {
  const v = read(storage)[feed] ?? DEFAULT_REACH[feed]
  return v === "webAndHop3" ? v : "web"
}
export function saveReach(feed, reach, storage = globalThis.localStorage) {
  const all = read(storage)
  all[feed] = reach === "webAndHop3" ? reach : "web"
  try { storage?.setItem(KEY, JSON.stringify(all)) } catch {}
}

/** The reach a feed choice judges with: "everyone" for a Global-style feed on Everyone and for a list you picked. */
export function feedReach(choice, storage = globalThis.localStorage) {
  if (choice.mode === "list") return "everyone"
  if (globalLike(choice) && choice.everyone) return "everyone"
  return loadReach(choice.mode, storage)
}

/**
 * A feed's notes through the gate, order kept. `always`: keys this feed always shows. -> { shown, outside }:
 * shown = inside + rationed hop 3, outside = the folded section's notes. Blocked notes are in neither. A reply to a
 * blocked person's note among these is blocked too (its parent's author is looked up in the same list).
 */
export function gateFeed(notes, web, { reach = "web", always = [] } = {}) {
  if (!notes) return { shown: notes, outside: [] }
  const byId = new Map(notes.map(n => [n.id, n]))
  const authorOf = id => byId.get(id)?.pubkey
  const verdicts = new Map(notes.map(n => [n, judgeNote(n, web, { authorOf, reach, always })]))
  const outside = notes.filter(n => verdicts.get(n) === VERDICTS.outside)
  const kept = notes.filter(n => verdicts.get(n) === VERDICTS.inside || verdicts.get(n) === VERDICTS.hop3)
  const shown = capHop3(kept, { verdict: n => verdicts.get(n), author: n => n.pubkey })
  return { shown, outside }
}
