// The Vault Dashboard (iPhone VaultDashboardView), a sheet over the screen it was opened from: "Vault Dashboard"
// with Done, then the phone's eight sections in its order: status, Is it safe?, Who can reach you, In your vault,
// Keep it full, Vault settings, Relay activity, Advanced. What a browser can't do is left out (an address and port,
// Start and Stop, Sync with Vault on Mac, clearing the media cache, publishing a relay list, Import media).
// Opened by "?sheet=dashboard" on any address (openDashboard), so Back closes it and the links in it leave it.
import { useEffect, useState } from "preact/hooks"
import { StatusCard } from "../components/dashboard/StatusCard.jsx"
import { SafetySection } from "../components/dashboard/SafetySection.jsx"
import { ReachSection } from "../components/dashboard/ReachSection.jsx"
import { ContentsSection } from "../components/dashboard/ContentsSection.jsx"
import { KeepFullSection } from "../components/dashboard/KeepFullSection.jsx"
import { SettingsSection } from "../components/dashboard/SettingsSection.jsx"
import { ActivitySection, ActivityWindow } from "../components/dashboard/ActivitySection.jsx"
import { AdvancedSection } from "../components/dashboard/AdvancedSection.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { useDmTrust } from "../components/useDmTrust.js"
import { routeClient, deviceKey } from "../haven/vault.js"
import { COUNT_ROUTES, countContents, scanMedia, readMedia } from "../net/vault-contents.js"
import { readHistory, markRan, onHistory } from "../net/vault-history.js"
import { activityItems } from "../net/relay-activity.js"
import { snapshotStore } from "../net/follow-backup.js"
import { mediaServers } from "../net/upload.js"
import { exportNotes, zip } from "../net/backup.js"
import { importOwn, IMPORT_START_DATE } from "../net/sync.js"
import { ownPostRelays } from "../net/own-relays.js"
import { saveFile } from "../net/save-file.js"
import { uniq } from "../net/pool.js"
import { APP_VERSION, APP_COMMIT } from "../net/settings.js"
import { closeDashboard } from "../net/dashboard-route.js"
import "../styles/dashboard.css"

const today = () => new Date().toISOString().slice(0, 10)
const toMs = t => (t > 1e12 ? t : t * 1000)

export function VaultDashboard({ ctx }) {
  const { vault, session, account } = ctx
  const me = session.pubkey
  const [view, setView] = useState("dashboard") // or "activity" (View All)
  const { blocked } = useBlocks(ctx)
  const trusted = useDmTrust(ctx)
  const [history, setHistory] = useState(() => readHistory(me))
  useEffect(() => onHistory(() => setHistory(readHistory(me))), [me])
  const [counts, setCounts] = useState({ contents: null, counting: true, failed: false })
  const [media, setMedia] = useState(null)
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
    scanMedia(me).then(setMedia).catch(() => setMedia(null))
    navigator.storage?.estimate?.().then(e => setStorage(s => ({ ...s, usage: e.usage }))).catch(() => {})
    navigator.storage?.persisted?.().then(p => setStorage(s => ({ ...s, kept: p }))).catch(() => {})
    snapshotStore(me).all().then(all => setFollowSavedAt(all.length ? toMs(Math.max(...all.map(x => x.savedAt ?? x.created_at))) : null)).catch(() => {})
    mediaServers(ctx).then(l => setServers(l.length)).catch(() => {})
  }
  useEffect(look, [me])
  // Escape closes the sheet wherever focus is (the HUD that opened it keeps focus), unless a dialog over it has it.
  // The desktop shell leaves the keys to the sheet while it is open (DesktopShell's OVERLAY), so l/r/j/k can't act
  // on the note behind it.
  useEffect(() => {
    const onKey = e => { if (e.key === "Escape" && !e.defaultPrevented && !document.querySelector("dialog[open]")) { e.preventDefault(); closeDashboard() } }
    addEventListener("keydown", onKey)
    return () => removeEventListener("keydown", onKey)
  }, [])

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
    const { found, stored } = await importOwn(vault, me, relays, { startDate: IMPORT_START_DATE,
      onProgress: p => setJobs(j => ({ ...j, importing: { progress: p.progress, text: `${p.empty ? "Looking through" : "Found"} notes from ${p.from}... (${p.found} found)` } })) })
    markRan(me, "notesImport")
    setJobs(j => ({ ...j, status: { text: `Import Complete! ${found} found, ${stored} new.` } }))
    count().catch(() => {})
  })

  const items = activityItems(globalThis.nvLog ?? [])
  const startedInMs = Number.isFinite(vault.loadMs) ? vault.loadMs + (vault.startMs ?? 0) : undefined
  const relayCount = uniq([...account.relays.read, ...account.relays.write]).length
  // Building who can reach you: the trust list is empty while follows' lists are still being read.
  const syncing = trusted.size === 0 && (account.follows?.length ?? 0) > 0
  return (
    <div class="dash-sheet" role="dialog" aria-modal="true" aria-labelledby="dash-title">
      <div class="dash-scrim" onClick={closeDashboard} />
      <div class="dash-panel">
        <header class="dash-bar-top">
          {view === "activity" ? <button type="button" class="dash-link" onClick={() => setView("dashboard")}>Back</button> : <span />}
          <h2 id="dash-title"><DashIcon />{view === "activity" ? "Relay Activity" : "Vault Dashboard"}</h2>
          <button type="button" class="dash-link done" onClick={closeDashboard} autofocus>Done</button>
        </header>
        <div class="dash-scroll">
          {view === "activity" ? <ActivityWindow items={items} version={`${APP_VERSION}${APP_COMMIT ? ` · ${APP_COMMIT}` : ""}`} /> : <>
            <StatusCard syncing={syncing} />
            <SafetySection method={session.method} followSavedAt={followSavedAt} backupAt={history.notesBackup} onBackup={exportFile} backupBusy={jobs.export} />
            <ReachSection trusted={trusted.size} blocked={blocked.size} />
            <ContentsSection {...counts} usage={storage.usage} kept={storage.kept} media={media} onRetry={look} />
            <KeepFullSection startDate={IMPORT_START_DATE} history={history} importing={jobs.importing} mediaBusy={jobs.media} exportBusy={jobs.export}
              status={jobs.status} onImport={importNotes} onMedia={mediaFile} onExport={exportFile} />
            <SettingsSection relays={relayCount} mediaServers={servers} />
            <ActivitySection items={items} onViewAll={() => setView("activity")} />
            <AdvancedSection startedInMs={startedInMs} />
          </>}
        </div>
      </div>
    </div>
  )
}

const DashIcon = () => <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 13h8V3H3zM13 21h8v-8h-8zM3 21h8v-6H3zM13 11h8V3h-8z" /></svg>
