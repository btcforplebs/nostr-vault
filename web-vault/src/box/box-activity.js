// The box's log (GET /api/box/logs) as Relay activity items (net/relay-activity.js): each line good, a heads-up or a
// problem by its words, redacted as every copy and report is. The box's log is the engine's and havend's own output,
// not the browser's, so its lines are read for their level rather than mapped type by type.
import { redact } from "../net/relay-activity.js"

const PROBLEM = /\b(error|failed|fail|panic|fatal|refused|denied|corrupt)\b/i
const HEADS_UP = /\b(warn|warning|retry|retrying|timeout|timed out|slow|backoff|stale|restart(ed|ing)?)\b/i

// Go's log prefix ("2026/11/22 02:07:28 ", the item has its own time) and terminal colours, taken off before showing.
const LOG_DATE = /^\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? /
const ANSI = /\u001b\[[0-9;]*m/g
/** A box log line's words: no colour codes, no Go date prefix (twice: havend's own log wraps the engine's line). */
export const lineText = text => String(text ?? "").replace(ANSI, "").replace(LOG_DATE, "").replace(LOG_DATE, "").trim()

export const lineLevel = text => (PROBLEM.test(text) ? "problem" : HEADS_UP.test(text) ? "headsUp" : "good")

/** Log lines -> [{ at (ms), level, text }], oldest first, as activityItems gives. */
export const boxActivityItems = (lines = []) => (lines ?? []).map(l => ({ at: (l.at ?? 0) * 1000, text: lineText(l.text) }))
  .filter(l => l.text).map(l => ({ at: l.at, level: lineLevel(l.text), text: redact(l.text) }))
