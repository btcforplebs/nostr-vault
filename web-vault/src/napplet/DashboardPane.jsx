// The Vault Dashboard as a napplet (plan NV_WEB_ONE_PLAN.md step 9), inside the shell's sheet (VaultDashboard.jsx) on
// the desktop while napplets are on. The shell reads with the sheet's own hooks and hands the napplet what each section
// draws (dashboard-answer.js); its buttons come back by name and run here. Link a device, the "Clear the cache?" ask,
// saving files and the clipboard stay the shell's.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { usePaneNapplet } from "./usePaneNapplet.js"
import { DASHBOARD_DTAG } from "./first-party.js"
import { dashboardAnswer, dashboardHandlers, DASHBOARD_TOPIC } from "./dashboard-answer.js"
import { useYourDevices } from "../components/dashboard/YourDevicesSection.jsx"
import { deviceStatus, statusLine } from "../desktop/space/my-devices.js"
import { deviceRows, pairedDevices } from "../net/pair-devices.js"
import { useWipeAlarms } from "../components/dashboard/ListWipeBanner.jsx"
import { useImportJobs } from "../components/dashboard/StillToBringIn.jsx"
import { useCache, CLEAR_TITLE, CLEAR_TEXT } from "../components/dashboard/CacheRow.jsx"
import { LAZARUS_URL } from "../components/dashboard/KeepFullSection.jsx"
import { sevenDayErase } from "../components/StorageNote.jsx"
import { Dialog } from "../components/Moderation.jsx"
import { report } from "../net/relay-activity.js"
import { saveFile } from "../net/save-file.js"
import { IMPORT_START_DATE } from "../net/sync.js"
import "./napplet.css"

export function DashboardPane({ ctx, d, onPair, version = "" }) {
  const host = useRef(null)
  const me = ctx.session.pubkey
  const loaded = useYourDevices(ctx)
  const { alarms, keep } = useWipeAlarms(ctx)
  const still = useImportJobs(ctx) // shown only where the sheet shows it (no box vault)
  const cache = useCache(me)
  const [asking, setAsking] = useState(false)
  const now = Math.floor(Date.now() / 1000)
  const devices = loaded ? deviceRows(loaded.devices, pairedDevices()).map(x => {
    const s = deviceStatus(loaded.adverts.get(x.hex), now, { checked: loaded.checked })
    return { title: x.title, state: s.state, line: statusLine(s, now) }
  }) : null
  const x = { dash: d, method: ctx.session.method, devices, alarms, still: ctx.vault.box ? null : still, cache }
  const latest = useRef(x)
  latest.current = x
  const pipe = useMemo(() => ({
    answer: () => dashboardAnswer(latest.current, { nowMs: Date.now(), start: performance.timeOrigin, safari: sevenDayErase(), startDate: IMPORT_START_DATE }),
    ctl: null,
  }), [])
  const text = () => report(latest.current.dash.items, { version })
  pipe.ctl = {
    go: hash => { location.hash = hash },
    lazarus: () => open(LAZARUS_URL, "_blank", "noopener,noreferrer"),
    run: job => ({ import: d.importNotes, skip: d.skip, media: d.mediaFile, export: d.exportFile, retry: d.look, restart: () => location.reload() })[job]?.(),
    history: on => d.setHistoryRelays(on),
    still: name => { const j = still.file.jobs.find(j => j.name === name); if (j) still.press(j) },
    cache: () => setAsking(true),
    keep: a => keep(a),
    pair: mode => onPair(mode),
    report: how => (how === "copy" ? navigator.clipboard?.writeText(text()).catch(() => {})
      : saveFile(new Blob([text()], { type: "text/plain" }), `nostrvault-relay-report-${new Date().toISOString().slice(0, 10)}.txt`).catch(() => {})),
  }
  const handlers = useMemo(() => dashboardHandlers(pipe).map(h => ({ id: `shell:${DASHBOARD_DTAG}`, title: "Nostr Vault", conventions: [], ...h })), [])
  const { live, note, ready } = usePaneNapplet(ctx, host, { dTag: DASHBOARD_DTAG, handlers })
  // Tell the napplet to ask again whenever what it would be handed changed.
  const key = ready ? JSON.stringify(pipe.answer().data) : ""
  useEffect(() => { if (ready) live.current?.bus.emit(live.current.me, DASHBOARD_TOPIC, {}) }, [key])
  return (
    <>
      {note && <p class="muted small">{note}</p>}
      <div class="napplet-host dash-napplet on" ref={host} />
      {asking && (
        <Dialog label={CLEAR_TITLE} onClose={() => setAsking(false)}>
          <h3>{CLEAR_TITLE}</h3>
          <p class="muted small">{CLEAR_TEXT}</p>
          <div class="mod-row">
            <button type="button" class="danger" onClick={() => { setAsking(false); cache.clear() }}>Clear</button>
            <button type="button" onClick={() => setAsking(false)}>Cancel</button>
          </div>
        </Dialog>
      )}
    </>
  )
}
