// The words of the Vault's "Still to bring in" (components/dashboard/StillToBringIn.jsx), as the apps say them (plan
// item 3). Pure, for tests.
import { relative } from "./vault-history.js"

export const JOB_TITLE = {
  setup: "Your notes, follows and lists",
  replies: "Replies and mentions",
  older_relays: "Older and slower relays",
  wider_network: "Your wider network",
  list_history: "Old versions of your lists",
}
export const JOB_ABOUT = {
  replies: "Replies, mentions and zaps to you, since the start date.",
  older_relays: "The relays setup couldn't finish, read back from where each stopped.",
  wider_network: "Who your follows follow, for the globe and Global.",
  list_history: "Older copies of your lists, for Recover a List.",
}
const about = s => (s < 90 ? `about ${s} s` : `about ${Math.round(s / 60)} min`)
const host = url => String(url).replace(/^wss?:\/\//, "").replace(/\/$/, "")
const WHY = { unreachable: "didn't connect", silent: "didn't answer", stopped_partway: "stopped partway", slow: "too slow", cut: "cut short",
  not_read_yet: "not read yet", deadline: "ran out of time" }

/** The line under a job's title: its state, its last run, how long it takes. */
export function jobLine(j, nowMs = Date.now()) {
  const when = j.ended_at ? relative(j.ended_at * 1000, nowMs) : ""
  const n = (j.stored ?? 0).toLocaleString()
  if (j.status === "running") return j.reason === "will_resume" ? "Picks up where it stopped" : `Running… ${n} so far`
  if (j.status === "done") return `Done ${when}: ${n} brought in.`
  if (j.status === "partial") return `Partly done ${when}: ${n} brought in. Not everything answered.`
  if (j.status === "failed") return `Didn't run ${when}: no relay answered.`
  if (j.status === "cancelled") return `Cancelled ${when}.`
  return `Never ran. Takes ${about(j.est_seconds)}.`
}

/** What a run couldn't read, one short line per range: "nostr.wine, 2023-01-01 to 2026-11-05: didn't answer". */
export const unreadLines = j => (j.unread ?? []).map(u => `${host(u.relay)}, ${u.from} to ${u.to}: ${WHY[u.why] ?? u.why}`)

/** The button: Cancel while running here, Run when it never ran, else Run again. */
export const jobButton = (j, runningHere) => (runningHere ? "Cancel" : j.status === "never" ? "Run" : "Run again")
