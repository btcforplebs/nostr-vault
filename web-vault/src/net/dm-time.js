// One rule for a direct message's time (dms.js, dm-cache.js).
/** A message's time, in seconds, as one the screens can draw. The rumor's created_at is the sender's claim and no relay
 *  sees it (it's inside the wrap): one past what a Date holds made every list that drew it throw (toISOString), on
 *  every load (bug hunt 2026-11-05 #3). Anything not a time, or more than a day ahead, reads as now. */
export function dmTime(t, now = Math.floor(Date.now() / 1000)) {
  const n = Number(t)
  if (!Number.isFinite(n) || n < 0) return 0
  return n > now + 86_400 ? now : Math.floor(n)
}
