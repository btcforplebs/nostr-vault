// How Settings › Recover a List words a list's versions and a merge (Logen 2026-11-02: who saved it, when, how many,
// what it changed, and "follow again" / "unfollow" rather than Comes back / Goes). Words only: the merge rules are in
// list-version-merge.js. Twins: Apple ListVersionLabels.swift, Android ListVersionLabels.kt.
import { mergeKind } from "./list-version-merge.js"

/** The app that saved a version: its first ["client", name] tag, else "An unknown app". */
export function clientName(ev) {
  const t = (ev?.tags ?? []).find(t => Array.isArray(t) && t[0] === "client" && typeof t[1] === "string" && t[1].trim())
  return t ? t[1].trim() : "An unknown app"
}

const plural = (n, noun) => n === 1 ? noun : /[^aeiou]y$/.test(noun) ? `${noun.slice(0, -1)}ies` : `${noun}s`
const num = n => n.toLocaleString("en-US")

/** "300 follows", "1 muted entry". */
export function countLine(kind, n) {
  return `${num(n)} ${plural(n, mergeKind(kind)?.noun ?? "entry")}`
}

/** What a version changed against the one before it: "+3, −709", "no change". */
export function changeLine({ added, removed }) {
  if (!added && !removed) return "no change"
  return [added && `+${num(added)}`, removed && `−${num(removed)}`].filter(Boolean).join(", ")
}

/** Section titles for what a merge or restore does to the list now. */
export function changeTitles(kind) {
  if (kind === 3) return { back: "Will follow again", gone: "Will unfollow", kept: "Still following" }
  if (kind === 10000) return { back: "Will mute again", gone: "Will unmute", kept: "Still muted" }
  return { back: "Will add back", gone: "Will remove", kept: "Already in your list" }
}

/** The merge entry's one line: what merge does, against restore. */
export const mergeExplainer = kind => kind === 3
  ? "Keeps everyone you follow now and adds back people older versions had."
  : "Keeps everything in your list now and adds back what older versions had."

/** The confirm's first line. `sum` from mergeSummary. */
export function saveLine(kind, name, sum) {
  if (!sum.added && !sum.removed) return "Nothing to bring back."
  if (kind === 3) return `Saves your follows: you follow ${num(sum.added)} again${sum.removed ? `, ${num(sum.removed)} unfollowed` : ""}.`
    + " Signed by you; the list you have now stays in your vault's history."
  const entries = n => `${num(n)} entr${n === 1 ? "y" : "ies"}`
  return `Saves your ${name.toLowerCase()} as ${entries(sum.total)}: ${sum.added} back${sum.removed ? `, ${sum.removed} taken out` : ""}.`
    + " Signed by you; the list you have now stays in your vault's history."
}

const count = (n, one, many) => `${num(n)} ${n === 1 ? one : many}`

/** What a mute merge mutes again, every type (Hal's point 11): "This mutes again: 3 people, 2 words, 1 hashtag,
 *  1 thread." "" when nothing. `r` = mergeSummary's remutes. */
export function remuteLine(r) {
  const parts = [
    r.people && count(r.people, "person", "people"), r.words && count(r.words, "word", "words"),
    r.hashtags && count(r.hashtags, "hashtag", "hashtags"), r.threads && count(r.threads, "thread", "threads"),
  ].filter(Boolean)
  return parts.length ? `This mutes again: ${parts.join(", ")}.` : ""
}

/** The left-out lines under the confirm: what an ordinary edit dropped later, and what can't be judged at all. */
export function leftOutLines({ leftOut = 0, unsure = 0 }) {
  const out = []
  // This browser's vault keeps only the copies it read, so another app's edits in between may be missing: an ordinary
  // edit isn't proof the user made it (Tron, PR 1595). Ticks stay as they are; only the claim is softened.
  if (leftOut) out.push(`${num(leftOut)} dropped in an ordinary edit ${leftOut === 1 ? "stays" : "stay"} out. Your vault only keeps the copies it saw, so it can't tell whether you or another app took ${leftOut === 1 ? "it" : "them"} out. Tap Review to add ${leftOut === 1 ? "it" : "them"}.`)
  if (unsure) out.push(`${num(unsure)} ${unsure === 1 ? "stays" : "stay"} out because the versions in between weren't all kept or couldn't be opened, so it can't be told whether you removed ${unsure === 1 ? "it" : "them"}. Tap Review to add ${unsure === 1 ? "it" : "them"}.`)
  return out
}

/** Said when the list now is NIP-04: the merge saves it with NIP-44, as every app's merge does (Logen 2026-11-03). */
/** The NIP-44 note shows only when the merge saves private entries over a NIP-04 list (Tron, PR 1595 nit). */
export const needsNip44Note = (kind, currentContent, rows) =>
  kind !== 3 && /\?iv=/.test(currentContent ?? "") && rows.some(r => r.ticked && r.private)

/** A Review row's note: when and how it left the list. "" for one in the list now or with no later version. */
export function entryNote(row, date) {
  if (row.status === "lost") return `Lost ${date(row.at)}`
  if (row.status === "removed") return `Dropped ${date(row.at)}, can't tell by whom`
  if (row.status === "unsure") return `Gone ${date(row.at)}, can't tell why`
  return ""
}

export const NIP44_NOTE = "Your private entries are saved with NIP-44, the newer encryption. An app that only reads the older kind won't see them."
