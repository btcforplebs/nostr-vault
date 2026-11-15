// The list wipe alarm on the Vault Dashboard (docs/LIST_WIPE_ALARM.md; iPhone ListWipeBanner.swift): a list that just
// lost most of what it held, from the vault's history, naming the app when it said who it was. Recover opens Recover
// a List on that list; nothing is restored or published until the user saves there. "Keep the new list" hides it.
import { useEffect, useState } from "preact/hooks"
import { readAlarms, alarmLine, dismissAlarm, WATCH_MS } from "../../net/list-wipe-alarm.js"
import { mergeKind } from "../../net/list-version-merge.js"

/** The alarms the banner shows (read again every `watchMs`), and "Keep the new list" for one. Shared with the
 *  Dashboard napplet (napplet/dashboard-answer.js). */
export function useWipeAlarms(ctx, watchMs = WATCH_MS) {
  const [alarms, setAlarms] = useState([])
  const me = ctx?.session?.pubkey
  useEffect(() => {
    let live = true
    const look = () => readAlarms(ctx).then(a => { if (live) setAlarms(a) }, () => {})
    look()
    const t = setInterval(look, watchMs)
    return () => { live = false; clearInterval(t) }
  }, [me])
  const keep = a => { dismissAlarm(a); setAlarms(l => l.filter(x => x.after.id !== a.after.id)) }
  return { alarms, keep }
}

export function ListWipeBanner({ ctx, watchMs = WATCH_MS }) {
  const { alarms, keep } = useWipeAlarms(ctx, watchMs)
  if (!alarms.length) return null
  return (
    <section class="dash-section list-wipe" aria-label="Lists that lost entries">
      {alarms.slice(0, 3).map(a => (
        <div key={a.after.id} class="list-wipe-card" role="alert">
          <p class="list-wipe-line">{alarmLine(a)}</p>
          <p class="muted small">
            {mergeKind(a.after.kind)
              ? "Your vault kept the list from before. Recover it? If you made this change yourself, keep the new list."
              : "Your vault kept the list from before. Restore it from the Nostr Vault app on your phone or Mac (List backups). If you made this change yourself, keep the new list."}
          </p>
          <div class="list-wipe-actions">
            {mergeKind(a.after.kind) && <a class="button primary" href={`#/settings/recover-list?kind=${a.after.kind}`}>Recover</a>}
            <button type="button" onClick={() => keep(a)}>Keep the new list</button>
          </div>
        </div>
      ))}
    </section>
  )
}
