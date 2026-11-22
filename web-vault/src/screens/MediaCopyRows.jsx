// Media Servers on a box (One Vault spec W5, iPhone BlossomSettingsView's Auto-Mirror toggle and MediaServersPage's
// Copy to servers): the box's engine runs both (box/api-media.js). Auto-Mirror copies into the box, every 3 hours,
// what your servers and your notes hold that the box doesn't. Copy to servers sends your files on the box to the
// servers above that lack them; the box has no key, so this browser signs the uploads, one signature per 25 files.
// Box mode only: a browser tab can't keep a schedule (spec 2.4), so the rows are hidden there.
import { useEffect, useRef, useState } from "preact/hooks"
import { mediaApi, signCopyAuths, lastRunLine } from "../box/api-media.js"

const POLL_MS = 2000
const POLL_FOR_MS = 30 * 60 * 1000
const wait = ms => new Promise(r => setTimeout(r, ms))
const plural = (n, one, many = `${one}s`) => `${n.toLocaleString()} ${n === 1 ? one : many}`

/** Polls the copy job until the one with `id` has finished. */
export async function untilDone(api, id, { pollMs = POLL_MS, forMs = POLL_FOR_MS, onState = () => {} } = {}) {
  const until = Date.now() + forMs
  for (;;) {
    const r = await api.copyState()
    if (r.state) onState(r.state)
    if (r.state?.id === id && !r.state.running && !r.queued) return r.state
    if (Date.now() > until) throw new Error("The box is still working on it. Check back in a while.")
    await wait(pollMs)
  }
}

export function MediaCopyRows({ ctx, api: given, pollMs }) {
  const api = useRef(given ?? mediaApi({ signer: ctx.signer })).current
  const readOnly = !!ctx.signer?.readOnly
  const [mirror, setMirror] = useState(null)
  const [mirrorErr, setMirrorErr] = useState("")
  const [busy, setBusy] = useState(false)
  const [job, setJob] = useState(null) // the last check or copy
  const [phase, setPhase] = useState("") // "", "checking", "signing", "copying"
  const [copyErr, setCopyErr] = useState("")

  useEffect(() => {
    if (readOnly) return
    api.autoMirror().then(setMirror).catch(e => setMirrorErr(String(e?.message ?? e)))
    api.copyState().then(r => setJob(r.state ?? null)).catch(() => {})
  }, [])

  const toggle = async () => {
    setBusy(true); setMirrorErr("")
    try { setMirror(await api.setAutoMirror(!mirror?.enabled)) } catch (e) { setMirrorErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const runNow = async () => {
    setBusy(true); setMirrorErr("")
    try { setMirror(await api.runAutoMirror()) } catch (e) { setMirrorErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }

  const missing = (job?.files ?? []).filter(f => f.status !== "copied")
  const failed = (job?.files ?? []).filter(f => f.status === "failed")
  const check = async () => {
    setPhase("checking"); setCopyErr("")
    try { const { id } = await api.checkCopy(); setJob(await untilDone(api, id, { pollMs, onState: setJob })) }
    catch (e) { setCopyErr(String(e?.message ?? e)) } finally { setPhase("") }
  }
  const copy = async () => {
    setCopyErr("")
    try {
      setPhase("signing")
      const auths = await signCopyAuths(ctx, missing.map(f => f.sha256))
      setPhase("copying")
      const { id } = await api.copy(auths)
      setJob(await untilDone(api, id, { pollMs, onState: setJob }))
    } catch (e) { setCopyErr(String(e?.message ?? e)) } finally { setPhase("") }
  }

  if (readOnly) return null
  const lastRun = mirror && lastRunLine(mirror)
  return (
    <>
      <div class="section-label">On this box</div>
      <label class="settings-row static">
        <span class="settings-title">Auto-Mirror Media</span>
        {mirror?.enabled && <button type="button" class="small" disabled={busy || mirror.state?.running} onClick={e => { e.preventDefault(); runNow() }}>Run now</button>}
        <input type="checkbox" role="switch" checked={!!mirror?.enabled} disabled={busy || !mirror} onChange={toggle} />
      </label>
      <p class="settings-note muted small">Every 3 hours the box copies in your files from the servers above and from links in your notes, up to 200 at a time.{lastRun ? ` ${lastRun}` : ""}</p>
      {mirrorErr && <p class="settings-note small error">{mirrorErr}</p>}

      <div class="settings-row static">
        <span class="settings-title">Copy to servers</span>
        <span class="settings-tags">
          <button type="button" class="small" disabled={!!phase} onClick={check}>{phase === "checking" ? "Checking…" : job?.checked_at ? "Check again" : "Check"}</button>
          {missing.length > 0 && <button type="button" class="small primary" disabled={!!phase} onClick={copy}>{phase === "signing" ? "Signing…" : phase === "copying" ? "Copying…" : failed.length ? "Retry" : `Copy ${plural(missing.length, "file")}`}</button>}
        </span>
      </div>
      <p class="settings-note muted small">{copyLine(job, phase, missing.length)}</p>
      {failed.slice(0, 5).map(f => (
        <p key={f.sha256} class="settings-note small error mono">{f.sha256.slice(0, 12)}…: {Object.entries(f.reasons ?? {}).map(([s, why]) => `${hostOf(s)} ${why}`).join("; ")}</p>
      ))}
      {failed.length > 5 && <p class="settings-note small error">and {plural(failed.length - 5, "more file")}.</p>}
      {job?.error && !phase && <p class="settings-note small error">{job.error}</p>}
      {copyErr && <p class="settings-note small error">{copyErr}</p>}
    </>
  )
}

const hostOf = url => { try { return new URL(url).host } catch { return url } }

/** The Copy to servers line: what the box is doing, or what the last check found. */
export function copyLine(job, phase, missing) {
  if (phase === "checking" || (job?.running && job.action === "check")) return "Asking each server which of your files it has…"
  if (phase === "signing") return "Approve the signature in your signer (one per 25 files)."
  if (phase === "copying" || job?.running) return `Sending… ${job?.copied ?? 0} copied so far.`
  if (!job?.checked_at) return "Send your files on this box to the servers above that don't have them yet."
  if (job.action === "copy" && (job.copied || job.failed)) return `${plural(job.copied ?? 0, "file")} copied${job.failed ? `, ${job.failed} failed` : ""}.${missing ? ` ${plural(missing, "file")} still to send.` : ""}`
  return missing ? `${plural(missing, "file")} of ${plural(job.checked ?? 0, "file")} on this box ${missing === 1 ? "is" : "are"} missing from a server.` : `All ${plural(job.checked ?? 0, "file")} on this box are on every server.`
}
