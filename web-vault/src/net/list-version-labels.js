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
