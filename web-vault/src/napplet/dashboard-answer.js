// The Vault Dashboard as a napplet (plan NV_WEB_ONE_PLAN.md step 9): the shell reads it with the sheet's own hooks
// (screens/VaultDashboard.jsx useVaultDashboard, useMyDevices, useWipeAlarms, useImportJobs, useCache) and hands the
// Dashboard napplet only the words, numbers and states each section draws, worked out by the sections' own word
// functions. No keys, ids or addresses cross: a row's link is a name from GO, a button is a job name, and a list alarm
// is the one id handed out. Pairing a device, the Clear cache ask and saving files stay the shell's.
//   napplet:dashboard/state {}                  -> { data } (dashboardAnswer)
//   napplet:dashboard/go { to }                 -> opens a page in GO, or "recover:<id>" for an alarm handed out
//   napplet:dashboard/run { job }               -> import | skip | media | export | retry | restart
//   napplet:dashboard/history { on }            -> Import notes also asks the history relays
//   napplet:dashboard/still { name }            -> Run / Run again / Cancel one long import job handed out
//   napplet:dashboard/cache {}                  -> the shell's "Clear the cache?" ask
//   napplet:dashboard/keep { id }               -> "Keep the new list" for an alarm handed out
//   napplet:dashboard/pair { mode }             -> the shell's Link a device (show | scan)
//   napplet:dashboard/report { how }            -> copy | export the activity report (the shell's clipboard and file)
// A change comes as inc nv.dashboard.changed.
import { keyRow } from "../components/dashboard/SafetySection.jsx"
import { blockedDetail, WEB_HOPS } from "../components/dashboard/ReachSection.jsx"
import { headerDetail, storageParts, statusText } from "../components/dashboard/ContentsSection.jsx"
import { cacheLine, MEDIA_NOTE } from "../components/dashboard/CacheRow.jsx"
import { uptimeLine, NO_START_STOP } from "../components/dashboard/StatusCard.jsx"
import { HISTORY_CHOICE, HISTORY_DETAIL, IMPORT_MEDIA_NOTE } from "../components/dashboard/KeepFullSection.jsx"
import { groupRows, kindName, MEDIA_BUCKETS, sizeText } from "../net/vault-contents.js"
import { relative, monthYear } from "../net/vault-history.js"
import { HEALTH, bannerDetail, health } from "../net/relay-activity.js"
import { LONG_JOBS } from "../net/import-jobs.js"
import { JOB_ABOUT, JOB_TITLE, jobButton, jobLine, unreadLines } from "../net/import-jobs-words.js"
import { alarmLine } from "../net/list-wipe-alarm.js"
import { mergeKind } from "../net/list-version-merge.js"
import { KEEP_IT } from "../components/StorageNote.jsx"

export const DASHBOARD_TOPIC = "nv.dashboard.changed"
/** The pages a row may open, by name. */
export const GO = {
  accounts: "#/accounts", "following-backup": "#/settings/following-backup", wot: "#/wot", blocked: "#/settings/blocked",
  relays: "#/settings/relays", mesh: "#/relay", "media-servers": "#/settings/media-servers", restore: "#/settings/backup", logs: "#/settings/logs",
}
export const JOBS = ["import", "skip", "media", "export", "retry", "restart"]
/** Activity lines handed over at most (View All draws them; the card the last three). */
export const ACTIVITY_CAP = 500
const GROUP_ICONS = { notes: "note", articles: "article", highlights: "highlight", reactions: "heart", zaps: "bolt", messages: "envelope", profile: "person", other: "more" }
const STORAGE_LINE = "This browser keeps a copy of your notes, and the browser can clear it. Your phone's vault is the real one."
const str = (v, n = 400) => String(v ?? "").slice(0, n)
const num = v => (Number.isFinite(v) ? v : 0)

/**
 * `x`: { dash: useVaultDashboard, method, devices: null | [{ id, title, state, line }], alarms, still: null | useImportJobs,
 *        cache: useCache }. `h`: { nowMs, start, safari }.
 * -> { data, alarms: Map id -> alarm handed out, still: Set of job names handed out }
 */
export function dashboardAnswer(x, h) {
  const d = x.dash, nowMs = h.nowMs
  const rel = at => relative(at, nowMs)
  const alarms = new Map(), still = new Set()

  const key = keyRow(x.method)
  const follow = !!d.followSavedAt, backup = !!d.history?.notesBackup
  const safety = {
    detail: `${[key.done, follow, backup].filter(Boolean).length} of 3`,
    rows: [
      { icon: "key", title: key.title, detail: key.detail, state: key.done ? "done" : "todo", go: "accounts" },
      { icon: "people", title: "Follow list saved", state: follow ? "done" : "todo", go: "following-backup",
        detail: follow ? `Last saved ${rel(d.followSavedAt)}.` : "Not saved yet. If a client wipes it, you can't get it back." },
      { icon: "zip", title: "Backup file", state: backup ? "done" : "todo", detail: backup ? `Last made ${rel(d.history.notesBackup)}.` : "Never made. Keep one somewhere off this device.",
        button: { title: backup ? "Make new" : "Make one", job: "export", busy: !!d.jobs.export } },
    ],
  }

  const c = d.counts ?? {}, mediaFiles = d.media
  const parts = storageParts(d.storage?.usage, mediaFiles?.size)
  const total = Math.max(1, parts.reduce((n, p) => n + p.size, 0))
  const contents = {
    detail: headerDetail(c.contents, d.storage?.usage),
    parts: parts.map(p => ({ title: p.title, cls: p.cls, size: sizeText(p.size), pct: p.size > 0 ? Math.max(1, (100 * p.size) / total) : 0 })),
    groups: c.contents ? groupRows(c.contents).map(r => ({ id: r.id, icon: GROUP_ICONS[r.id] ?? "more", title: r.title, value: r.count.toLocaleString(),
      detail: r.yours != null ? `${r.yours.toLocaleString()} yours` : "", lines: r.kinds.length > 1 ? r.kinds.map(k => ({ title: kindName(k.kind), value: k.count.toLocaleString() })) : [] })) : [],
    status: !c.contents || c.counting || c.failed ? { counting: !!c.counting, text: statusText({ counting: c.counting }) } : null,
    media: { value: mediaFiles ? mediaFiles.count.toLocaleString() : "—", detail: mediaFiles ? sizeText(mediaFiles.size) : "",
      lines: MEDIA_BUCKETS.filter(([k]) => mediaFiles?.buckets?.[k]?.count > 0).map(([k, t]) => ({ title: t, value: `${mediaFiles.buckets[k].count.toLocaleString()} · ${sizeText(mediaFiles.buckets[k].size)}` })) },
    cache: { line: cacheLine(x.cache?.n ?? null, !!x.cache?.done), busy: !!x.cache?.busy, can: !x.cache?.busy && (x.cache?.n ?? 0) > 0 },
    mediaNote: MEDIA_NOTE,
    storage: { line: STORAGE_LINE, safari: KEEP_IT[h.safari] ?? "", kept: d.storage?.kept === undefined ? null : !!d.storage.kept },
  }

  const imp = d.jobs.importing, busy = !!imp || !!d.jobs.media || !!d.jobs.export
  const hist = d.history ?? {}
  const keep = {
    import: { detail: imp ? str(imp.text) : `Since ${monthYear(h.startDate)}. ${hist.notesImport ? `Last ran ${rel(hist.notesImport)}.` : "Never ran."}`,
      progress: imp ? Math.min(1, Math.max(0, num(imp.progress))) : null, skippable: !!imp?.skippable, busy: !!imp, disabled: busy },
    history: { on: !!d.historyRelays, disabled: !!imp, title: HISTORY_CHOICE, detail: HISTORY_DETAIL },
    media: { detail: hist.mediaBackup ? `Last made ${rel(hist.mediaBackup)}.` : "Never made.", busy: !!d.jobs.media, disabled: busy },
    export: { detail: hist.notesBackup ? `Last made ${rel(hist.notesBackup)}.` : "Never made.", busy: !!d.jobs.export, disabled: busy },
    status: d.jobs.status ? { text: str(d.jobs.status.text), error: !!d.jobs.status.error } : null,
    note: IMPORT_MEDIA_NOTE,
  }

  let stillData = null
  if (x.still) {
    const s = x.still
    stillData = {
      rows: s.file.jobs.filter(j => LONG_JOBS.includes(j.name)).map(j => {
        still.add(j.name)
        const mine = s.here === j.name
        return { name: j.name, title: JOB_TITLE[j.name], detail: str([jobLine(j, nowMs), JOB_ABOUT[j.name], ...unreadLines(j)].join(" "), 2000),
          state: j.status === "done" ? "done" : j.status === "partial" || j.status === "failed" ? "todo" : "info", button: jobButton(j, mine), busy: mine, disabled: !mine && s.busy }
      }),
      note: str(s.note),
    }
  }

  const wipes = (x.alarms ?? []).slice(0, 3).map(a => {
    const id = String(a.after.id)
    alarms.set(id, a)
    const recover = !!mergeKind(a.after.kind)
    return { id, line: str(alarmLine(a)), recover, text: recover
      ? "Your vault kept the list from before. Recover it? If you made this change yourself, keep the new list."
      : "Your vault kept the list from before. Restore it from the Nostr Vault app on your phone or Mac (List backups). If you made this change yourself, keep the new list." }
  })

  const items = d.items ?? [], hl = health(items)
  const rows = x.devices
  const onMesh = rows ? rows.filter(r => r.state === "online" || r.state === "connected").length : 0
  return {
    alarms, still,
    data: {
      status: { title: "Your vault is running", line: d.syncing ? "Updating who can reach you…" : uptimeLine(h.start, nowMs), note: NO_START_STOP },
      devices: { rows: rows ? rows.map(r => ({ title: str(r.title, 120), state: str(r.state, 20), line: str(r.line, 200) })) : null, detail: rows?.length ? `${onMesh} of ${rows.length} on the mesh` : "" },
      wipes, safety,
      reach: [
        { icon: "crowd", go: "wot", title: d.trusted ? `${d.trusted.toLocaleString()} people can reach your inbox` : "Trust list not built yet", detail: `People within ${WEB_HOPS} hops of you. Everyone else is kept out.` },
        { icon: "hand", go: "blocked", title: "Blocked", detail: blockedDetail(d.blocked ?? 0) },
      ],
      contents, still: stillData, keep,
      settings: { relays: d.relayCount ?? null, hops: `${WEB_HOPS} hops`, servers: d.servers ?? null },
      activity: { health: hl, pill: HEALTH[hl].pill, banner: HEALTH[hl].banner, bannerDetail: str(bannerDetail(items)),
        items: items.slice(-ACTIVITY_CAP).map(i => ({ level: str(i.level, 20), text: str(i.text, 500), at: num(i.at) })) },
      advanced: { running: uptimeLine(h.start, nowMs).replace(/^Up /, ""), startedIn: Number.isFinite(d.startedInMs) ? `${d.startedInMs} ms` : "" },
    },
  }
}

/** `pipe`: { answer() -> dashboardAnswer | null, ctl }. `ctl`: { run(job), history(on), still(name), cache(), keep(alarm),
 *  pair(mode), report(how), go(hash) }. -> handlers for usePaneNapplet (one napplet on its own bus). */
export function dashboardHandlers(pipe) {
  let handed = { alarms: new Map(), still: new Set() }
  const h = (action, run) => ({ archetype: "dashboard", actions: [action], deliver: p => run(p ?? {}) })
  const ok = { ok: true }
  return [
    h("state", () => {
      const a = pipe.answer()
      if (!a) return { ok: true, data: null }
      handed = { alarms: a.alarms, still: a.still }
      return { ok: true, data: a.data }
    }),
    h("go", p => {
      const to = typeof p.to === "string" ? p.to : ""
      if (Object.hasOwn(GO, to)) { pipe.ctl.go(GO[to]); return ok }
      const m = /^recover:(.+)$/.exec(to), a = m && handed.alarms.get(m[1])
      if (a && mergeKind(a.after.kind)) { pipe.ctl.go(`#/settings/recover-list?kind=${a.after.kind}`); return ok }
      if (to === "lazarus") { pipe.ctl.lazarus(); return ok }
      return { ok: false, error: "not a page the Dashboard opens" }
    }),
    h("run", p => (JOBS.includes(p.job) ? (pipe.ctl.run(p.job), ok) : { ok: false, error: "not a Dashboard job" })),
    h("history", p => (typeof p.on === "boolean" ? (pipe.ctl.history(p.on), ok) : { ok: false, error: "on is true or false" })),
    h("still", p => (handed.still.has(p.name) ? (pipe.ctl.still(p.name), ok) : { ok: false, error: "not a job this Dashboard shows" })),
    h("cache", () => { pipe.ctl.cache(); return ok }),
    h("keep", p => { const a = handed.alarms.get(p.id); if (!a) return { ok: false, error: "not an alarm this Dashboard shows" }; pipe.ctl.keep(a); return ok }),
    h("pair", p => (p.mode === "show" || p.mode === "scan" ? (pipe.ctl.pair(p.mode), ok) : { ok: false, error: "show or scan" })),
    h("report", p => (p.how === "copy" || p.how === "export" ? (pipe.ctl.report(p.how), ok) : { ok: false, error: "copy or export" })),
  ]
}
