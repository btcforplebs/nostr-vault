// Backups on your box (One Vault W4; Mac Is it safe? › Backup & Restore): Back up now, and Restore on each of the box's
// own backups. The box stops its vault for each (a few seconds), so the line under the buttons says where it is. First
// account only: the box's backups hold every account's notes. `api`: a boxApi.
import { useEffect, useState } from "preact/hooks"
import { Row, RowButton, Section } from "../components/dashboard/parts.jsx"
import { sizeText } from "../net/vault-contents.js"

const PHASE = { stopping: "Stopping the vault…", working: "Working…", starting: "Starting the vault again…" }
const KIND = { backup: "Backup", restore: "Restore", restart: "Restart" }
const when = s => new Date(s * 1000).toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" })

/** The job line: where a backup, restore or restart is, or how the last one ended. */
export function jobText(job) {
  if (!job) return ""
  if (PHASE[job.phase]) return `${KIND[job.kind] ?? "Job"}: ${PHASE[job.phase]}`
  if (job.phase === "failed") return `${KIND[job.kind] ?? "Job"} failed: ${job.error ?? "the box didn't say why"}`
  return job.kind === "restore" ? `Restored ${job.name} at ${when(job.finishedAt)}.` : job.kind === "backup" ? `Backed up at ${when(job.finishedAt)}.` : `Restarted at ${when(job.finishedAt)}.`
}
const running = job => !!job && !!PHASE[job.phase]

export function BoxBackupSection({ api, confirmFn = q => globalThis.confirm?.(q) ?? true }) {
  const [data, setData] = useState(null) // { backups, job } | { error }
  const [note, setNote] = useState("")
  const load = () => api.backups().then(d => setData({ backups: d.backups ?? [], job: d.job ?? null }), e => setData({ error: String(e?.message ?? e) }))
  useEffect(() => { load() }, [api])
  useEffect(() => {
    if (!running(data?.job)) return
    const t = setInterval(load, 1500)
    return () => clearInterval(t)
  }, [data?.job?.phase])
  const start = fn => async () => {
    setNote("")
    try { const job = await fn(); setData(d => ({ ...d, job })) } catch (e) { setNote(String(e?.message ?? e)) }
  }
  const busy = running(data?.job)
  return (
    <Section title="Backups on your box" detail={data?.backups ? `${data.backups.length} kept` : undefined}>
      {!data ? <div class="dash-row"><span class="dash-sub">Asking your box…</span></div>
        : data.error ? <div class="dash-row dash-note error" role="alert">{data.error}</div> : <>
          <Row icon="zip" title="Back up now" detail="A copy of every note on the box, kept on the box. The newest 5 stay.">
            <RowButton title="Back up" busy={busy && data.job?.kind === "backup"} disabled={busy} onClick={start(api.backupNow)} />
          </Row>
          {data.backups.map(b => (
            <Row key={b.name} icon="stack" title={when(b.createdAt)} detail={sizeText(b.size)}>
              <RowButton title="Restore" busy={busy && data.job?.kind === "restore" && data.job?.name === b.name} disabled={busy}
                onClick={() => confirmFn(`Restore the backup from ${when(b.createdAt)}? The box adds its notes to the vault (nothing is deleted) and stops the vault for a moment.`) && start(() => api.restore(b.name))()} />
            </Row>
          ))}
          {(data.job || note) && <div class={`dash-row dash-note${data.job?.phase === "failed" || note ? " error" : ""}`} role="status">{note || jobText(data.job)}</div>}
        </>}
    </Section>
  )
}
