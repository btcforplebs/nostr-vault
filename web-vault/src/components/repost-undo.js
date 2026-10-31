// The repost button's send delay, as the iPhone's PendingPostManager + PostActionPill: "Reposting in 5s" with Undo in
// the shared toast while it counts down, then "Reposted" once a relay took it, or why it didn't go out. Off (0 s)
// reposts at once and only says Reposted.
import { repostAfterDelay } from "../net/actions.js"
import { SEND_ACTIONS, countdownText, sendDelaySeconds } from "../net/send-delay.js"
import { hideToast, showToast } from "./Toast.jsx"

/** Repost `note` behind the countdown pill. -> repostAfterDelay's handle. `seconds`, `countdown` are for tests. */
export function repostWithUndo(ctx, note, { seconds = sendDelaySeconds(), countdown } = {}) {
  const key = `repost:${note.id}`
  let handle
  const pill = remaining => showToast({ key, icon: "repost", seconds: 0, message: countdownText("repost", remaining),
    action: { label: "Undo", onClick: () => handle?.cancel() } })
  handle = repostAfterDelay(ctx, note, { seconds, onTick: pill, ...(countdown ? { countdown } : {}) })
  if (seconds > 0) pill(seconds)
  handle.done.then(result => {
    if (result === "sent") showToast({ key, icon: "repost", tone: "success", message: SEND_ACTIONS.repost.done })
    else if (result === "failed") showToast({ key, icon: "warn", tone: "error", message: "Repost failed: no relay took it" })
    else if (result === "undone") hideToast(key)
  })
  return handle
}
