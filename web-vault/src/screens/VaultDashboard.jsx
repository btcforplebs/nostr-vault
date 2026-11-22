// The Vault Dashboard (iPhone VaultDashboardView), a sheet over the screen it was opened from: "Vault Dashboard"
// with Done, then the phone's eight sections in its order: status, Is it safe?, Who can reach you, In your vault,
// Keep it full, Vault settings, Relay activity, Advanced. What a browser can't do is left out (an address and port,
// Start and Stop, Sync with Vault on Mac, clearing the media cache, publishing a relay list, Import media).
// Opened by "?sheet=dashboard" on any address (openDashboard), so Back closes it and the links in it leave it.
// In box mode (One Vault W1) it is the box's dashboard: status, storage, media, connections and log come from the box
// (box/useBoxDashboard.js), the counts from the box's relay, and the old Box screen's sections fold in (box/BoxFold.jsx).
import { useEffect, useRef, useState } from "preact/hooks"
import { StatusCard } from "../components/dashboard/StatusCard.jsx"
import { SafetySection } from "../components/dashboard/SafetySection.jsx"
import { ListWipeBanner } from "../components/dashboard/ListWipeBanner.jsx"
import { ReachSection } from "../components/dashboard/ReachSection.jsx"
import { ContentsSection } from "../components/dashboard/ContentsSection.jsx"
import { HISTORY_DEFAULT_ON, KeepFullSection } from "../components/dashboard/KeepFullSection.jsx"
import { SettingsSection } from "../components/dashboard/SettingsSection.jsx"
import { ActivitySection, ActivityWindow } from "../components/dashboard/ActivitySection.jsx"
import { AdvancedSection } from "../components/dashboard/AdvancedSection.jsx"
import { StillToBringIn } from "../components/dashboard/StillToBringIn.jsx"
import { YourDevicesSection } from "../components/dashboard/YourDevicesSection.jsx"
import { PairDevice } from "./PairDevice.jsx"
import { DashboardPane } from "../napplet/DashboardPane.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { useDmTrust } from "../components/useDmTrust.js"
import { routeClient, deviceKey } from "../haven/vault.js"
import { COUNT_ROUTES, countContents, scanMedia, readMedia } from "../net/vault-contents.js"
import { readGreetings } from "../net/greeting-counts.js"
import { readHistory, markRan, onHistory } from "../net/vault-history.js"
import { activityItems } from "../net/relay-activity.js"
import { snapshotStore } from "../net/follow-backup.js"
import { mediaServers } from "../net/upload.js"
import { exportNotes, zip } from "../net/backup.js"
import { importOwn, importLine, IMPORT_START_DATE } from "../net/sync.js"
import { importListHistory, historyLine } from "../net/list-history-import.js"
import { ownPostRelays } from "../net/own-relays.js"
import { saveFile } from "../net/save-file.js"
import { uniq } from "../net/pool.js"
import { APP_VERSION, APP_COMMIT } from "../net/settings.js"
import { closeDashboard } from "../net/dashboard-route.js"
import { useBoxDashboard, boxStorage } from "../box/useBoxDashboard.js"
import { boxActivityItems } from "../box/box-activity.js"
import { BoxLogView } from "../box/BoxLogView.jsx"
import { BoxStatusDetails, BoxDevices, BoxStorage, BoxPublic, BoxUpdate } from "../box/BoxFold.jsx"
import { useBoxJobs } from "../box/useBoxJobs.js"
import { BoxStillToBringIn } from "../box/BoxStillToBringIn.jsx"
import { BoxBackupSection } from "../box/BoxBackupSection.jsx"
import { Row, RowButton } from "../components/dashboard/parts.jsx"
import "../styles/dashboard.css"

const today = () => new Date().toISOString().slice(0, 10)
const toMs = t => (t > 1e12 ? t : t * 1000)

/** The Dashboard's data and jobs (shared with the Dashboard napplet, napplet/dashboard-answer.js): counts, media,
 *  storage, the follow-list save, media servers, the import/backup/export jobs and the activity log. */
export function useVaultDashboard(ctx) {
  const { vault, session, account } = ctx
  const me = session.pubkey
  // Import notes: also ask the history relays (the user's tick, off each time the sheet opens), and the Skip button's
  // signal for the list scan.
  const [historyRelays, setHistoryRelays] = useState(HISTORY_DEFAULT_ON)
  const skip = useRef(null)
  const { blocked } = useBlocks(ctx)
  const trusted = useDmTrust(ctx)
  const [history, setHistory] = useState(() => readHistory(me))
  useEffect(() => onHistory(() => setHistory(readHistory(me))), [me])
  const [counts, setCounts] = useState({ contents: null, counting: true, failed: false })
  const [media, setMedia] = useState(null)
  const [greetings, setGreetings] = useState(null)
  const [storage, setStorage] = useState({})
  const [followSavedAt, setFollowSavedAt] = useState(null)
  const [servers, setServers] = useState(null)
  const [jobs, setJobs] = useState({ importing: null, media: false, export: false, status: null })

  const count = async () => {
    setCounts(c => ({ ...c, counting: true, failed: false }))
    const sk = deviceKey(), clients = COUNT_ROUTES.map(r => routeClient(vault.haven, r, sk, `dash${r.replace("/", "-")}`))
    try {
      const contents = await countContents(clients, me)
      setCounts({ contents, counting: false, failed: !contents })
    } finally { for (const c of clients) c.close() }
  }
  const look = () => {
    count().catch(() => setCounts({ contents: null, counting: false, failed: true }))
    // A box's media files are the box's (GET /api/box/contents): this browser keeps none.
    if (!vault.box) scanMedia(me).then(setMedia).catch(() => setMedia(null))
    // Your own GM / Pura Vida notes, from this browser's vault only (net/greeting-counts.js). Can't answer: keep the last.
    readGreetings(vault.outbox, me).then(g => { if (g) setGreetings(g) })
    navigator.storage?.estimate?.().then(e => setStorage(s => ({ ...s, usage: e.usage }))).catch(() => {})
    navigator.storage?.persisted?.().then(p => setStorage(s => ({ ...s, kept: p }))).catch(() => {})
    snapshotStore(me).all().then(all => setFollowSavedAt(all.length ? toMs(Math.max(...all.map(x => x.savedAt ?? x.created_at))) : null)).catch(() => {})
    mediaServers(ctx).then(l => setServers(l.length)).catch(() => {})
  }
  useEffect(look, [me])

  const job = (key, fn) => async () => {
    setJobs(j => ({ ...j, [key]: true, status: null }))
    try { await fn() } catch (e) { setJobs(j => ({ ...j, status: { text: String(e?.message ?? e), error: true } })) } finally { setJobs(j => ({ ...j, [key]: key === "importing" ? null : false })) }
  }
  const exportFile = job("export", async () => {
    setJobs(j => ({ ...j, status: { text: "Preparing notes backup…" } }))
    const { blob } = await exportNotes({ vault, pubkey: me })
    const how = await saveFile(blob, `nostrvault-backup-${today()}.zip`)
    if (how === "cancelled") return setJobs(j => ({ ...j, status: { text: "Export cancelled" } }))
    markRan(me, "notesBackup")
    setJobs(j => ({ ...j, status: { text: "Ready to share" } }))
  })
  const mediaFile = job("media", async () => {
    setJobs(j => ({ ...j, status: { text: "Preparing media backup…" } }))
    const files = await readMedia(me)
    if (!files.length) return setJobs(j => ({ ...j, status: { text: "No media files in this browser's vault yet." } }))
    const blob = new Blob([await zip(files)], { type: "application/zip" })
    const how = await saveFile(blob, `nostrvault-media-${today()}.zip`)
    if (how === "cancelled") return setJobs(j => ({ ...j, status: { text: "Export cancelled" } }))
    markRan(me, "mediaBackup")
    setJobs(j => ({ ...j, status: { text: "Ready to share" } }))
  })
  const importNotes = job("importing", async () => {
    setJobs(j => ({ ...j, importing: { progress: 0, text: "Connecting to relays..." } }))
    const relays = ownPostRelays(account)
    const result = await importOwn(vault, me, relays, { startDate: IMPORT_START_DATE,
      onProgress: p => setJobs(j => ({ ...j, importing: { progress: p.progress, text: `${p.empty ? "Looking through" : "Found"} notes from ${p.from}... (${p.found} found)` } })) })
    // Moving in also brings back older versions of the user's lists (net/list-history-import.js): filed in the vault's
    // list history for Recover a List, never published, never made the current list.
    // Only when ticked (one rule with the apps): unticked, no relay is asked, the user's own included. Skip ends the
    // scan; what it found by then is still filed, and the import ends.
    skip.current = new AbortController()
    if (historyRelays) setJobs(j => ({ ...j, importing: { progress: 1, text: "Looking for older versions of your lists...", skippable: true } }))
    const lists = await importListHistory(ctx, { history: historyRelays, signal: skip.current.signal,
      onProgress: p => setJobs(j => ({ ...j, importing: { progress: p.done / p.total, text: `Looking for older versions of your lists... (${p.found} found)`, skippable: true } })),
    }).catch(() => ({ found: 0, answered: 0 })).finally(() => { skip.current = null })
    // "Last ran" moves only for a complete import, as the apps record it (audit item 12).
    if (result.result === "complete") markRan(me, "notesImport")
    setJobs(j => ({ ...j, status: { text: `${importLine(result)} ${historyLine(lists)}`.trim(), error: result.result === "failed" } }))
    count().catch(() => {})
  })

  const items = activityItems(globalThis.nvLog ?? [])
  const startedInMs = Number.isFinite(vault.loadMs) ? vault.loadMs + (vault.startMs ?? 0) : undefined
  const relayCount = uniq([...account.relays.read, ...account.relays.write]).length
  // Building who can reach you: the trust list is empty while follows' lists are still being read.
  const syncing = trusted.size === 0 && (account.follows?.length ?? 0) > 0
  return { me, counts, media, greetings, storage, followSavedAt, servers, jobs, history, historyRelays, setHistoryRelays, look, exportFile, mediaFile, importNotes,
    skip: () => skip.current?.abort(), items, startedInMs, relayCount, syncing, trusted: trusted.size, blocked: blocked.size }
}

/** `napplet`: the desktop with napplets on, where the dashboard itself is the Dashboard napplet (one plan step 9). */
/** `boxOptions`: useBoxDashboard's options (tests turn box mode on and pass a mock box). */
export function VaultDashboard({ ctx, napplet = false, boxOptions }) {
  const { vault, session } = ctx
  const d = useVaultDashboard(ctx)
  const box = useBoxDashboard(ctx, boxOptions)
  const bj = useBoxJobs(box, ctx) // the box's imports, trust, backups and restart (W4)
  const { counts, greetings, storage, followSavedAt, servers, jobs, history, historyRelays, setHistoryRelays, exportFile, mediaFile, importNotes, startedInMs, relayCount, syncing } = d
  const onBox = boxStorage(box?.data.contents)
  const media = box ? onBox.media : d.media
  const look = box ? () => { d.look(); box.look() } : d.look
  const items = box ? boxActivityItems(box.data.logs?.value?.lines) : d.items
  const [view, setView] = useState("dashboard") // or "activity" (View All), "logs" (the box's full log), or "pair" (Link a device)
  const [pairMode, setPairMode] = useState("show") // PairDevice: "show" this browser's code or "scan" the other's
  const pair = mode => { setPairMode(mode); setView("pair") }
  // Escape closes the sheet wherever focus is (the HUD that opened it keeps focus), unless a dialog over it has it.
  // The desktop shell leaves the keys to the sheet while it is open (DesktopShell's OVERLAY), so l/r/j/k can't act
  // on the note behind it.
  useEffect(() => {
    const onKey = e => { if (e.key === "Escape" && !e.defaultPrevented && !document.querySelector("dialog[open]")) { e.preventDefault(); closeDashboard() } }
    addEventListener("keydown", onKey)
    return () => removeEventListener("keydown", onKey)
  }, [])
  return (
    <div class="dash-sheet" role="dialog" aria-modal="true" aria-labelledby="dash-title">
      <div class="dash-scrim" onClick={closeDashboard} />
      <div class="dash-panel">
        <header class="dash-bar-top">
          {view !== "dashboard" ? <button type="button" class="dash-link" onClick={() => setView("dashboard")}>Back</button> : <span />}
          <h2 id="dash-title"><DashIcon />{view === "activity" ? "Vault Activity" : view === "logs" ? "Box Log" : view === "pair" ? "Link a device" : "Vault Dashboard"}</h2>
          <button type="button" class="dash-link done" onClick={closeDashboard} autofocus>Done</button>
        </header>
        <div class={view === "dashboard" && napplet ? "dash-scroll napp" : "dash-scroll"}>
          {view === "dashboard" && napplet ? <DashboardPane ctx={ctx} d={d} onPair={pair} version={`${APP_VERSION}${APP_COMMIT ? ` · ${APP_COMMIT}` : ""}`} />
          : view === "activity" ? <ActivityWindow items={items} version={`${APP_VERSION}${APP_COMMIT ? ` · ${APP_COMMIT}` : ""}`} onFullLogs={box ? () => setView("logs") : undefined} />
          : view === "logs" && box ? <BoxLogView state={box.data.logs} />
          : view === "pair" ? <PairDevice key={pairMode} ctx={ctx} mode={pairMode} onMode={setPairMode} onClose={() => setView("dashboard")} /> : <>
            <StatusCard syncing={syncing} box={box ? { status: box.data.status, connections: box.data.connections, onRestart: bj?.first ? bj.restart : undefined } : undefined} />
            {box && <BoxStatusDetails box={box} />}
            {box ? <BoxDevices box={box} /> : <YourDevicesSection ctx={ctx} onPair={pair} />}
            <ListWipeBanner ctx={ctx} />
            <SafetySection method={session.method} followSavedAt={followSavedAt} backupAt={history.notesBackup} onBackup={exportFile} backupBusy={jobs.export} />
            <ReachSection trusted={d.trusted} blocked={d.blocked}>
              {bj && <Row icon="crowd" title="Rebuild who can reach you" detail={bj.trust.note || "Your box rebuilds its trust list now, instead of at the daily rebuild."}>
                <RowButton title="Rebuild now" busy={bj.trust.rebuilding} onClick={bj.trust.rebuild} />
              </Row>}
            </ReachSection>
            <ContentsSection {...counts} usage={box ? onBox.usage : storage.usage} kept={storage.kept} media={media} onRetry={look} me={session.pubkey} greetings={greetings} box={!!box}>
              {box && <BoxStorage box={box} />}
            </ContentsSection>
            {bj ? <BoxStillToBringIn imports={bj.imports} /> : !vault.box && <StillToBringIn ctx={ctx} />}
            <KeepFullSection startDate={IMPORT_START_DATE} history={history} importing={jobs.importing} mediaBusy={jobs.media} exportBusy={jobs.export}
              status={jobs.status} onImport={importNotes} onMedia={mediaFile} onExport={exportFile}
              historyRelays={historyRelays} onHistoryRelays={setHistoryRelays} onSkip={d.skip}
              {...(bj && { ...bj.keepFull, box: true, onHistoryRelays: undefined, onSkip: undefined })} />
            {bj?.first && <BoxBackupSection api={bj.api} />}
            <SettingsSection relays={relayCount} mediaServers={servers} />
            {box && <BoxPublic ctx={ctx} box={box} />}
            <ActivitySection items={items} onViewAll={() => setView("activity")} />
            {box ? <AdvancedSection box={box.data.status?.value ?? null}><BoxUpdate box={box} /></AdvancedSection> : <AdvancedSection startedInMs={startedInMs} />}
          </>}
        </div>
      </div>
    </div>
  )
}

const DashIcon = () => <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 13h8V3H3zM13 21h8v-8h-8zM3 21h8v-6H3zM13 11h8V3h-8z" /></svg>
