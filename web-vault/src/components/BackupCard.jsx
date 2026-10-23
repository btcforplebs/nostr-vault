// The one backup (iOS Settings › Backup › Notes): the same .zip the phone makes, so each restores the other's.
// Restore also reads the .jsonl files this web app used to download, so an older backup still comes back.
import { useState } from "preact/hooks"
import { exportNotes, importNotes } from "../net/backup.js"
import { parseBackup, restoreBackup } from "../net/settings.js"

const NAMES = { outbox: "your notes", private: "private notes", chat: "messages", inbox: "inbox", feed: "feed cache" }
const summary = counts => Object.entries(counts).map(([n, c]) => `${NAMES[n] ?? n} ${typeof c === "number" ? c : c.stored}`).join(", ")
const events = n => n === 1 ? "1 event" : `${n} events`
const SKIPPED = { unreadable: "unreadable", badSignature: "with a bad signature", notYours: "not yours" }

/** A file is the phone's .zip by its first bytes (PK), whatever it's named; anything else is read as JSON lines. */
export const isZip = bytes => bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 3 && bytes[3] === 4

export function BackupCard({ ctx }) {
  const [busy, setBusy] = useState("")
  const [status, setStatus] = useState("")
  const [err, setErr] = useState("")
  const run = (label, fn) => async () => {
    setBusy(label); setErr(""); setStatus("")
    try { await fn() } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy("") }
  }
  const doExport = run("export", async () => {
    const { blob, counts } = await exportNotes({ vault: ctx.vault, pubkey: ctx.session.pubkey, onProgress: n => setStatus(`Reading ${NAMES[n] ?? n}…`) })
    const url = URL.createObjectURL(blob)
    const a = Object.assign(document.createElement("a"), { href: url, download: `nostrvault-backup-${new Date().toISOString().slice(0, 10)}.zip` })
    document.body.append(a); a.click(); a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 60_000)
    setStatus(`Saved: ${summary(counts)}.`)
  })
  const doImport = e => {
    const file = e.currentTarget.files?.[0]
    e.currentTarget.value = ""
    if (!file) return
    run("import", async () => {
      const bytes = new Uint8Array(await file.arrayBuffer())
      if (!isZip(bytes)) return restoreLines(new TextDecoder().decode(bytes))
      const { counts, skipped, failed } = await importNotes({ vault: ctx.vault, pubkey: ctx.session.pubkey, bytes, onProgress: n => setStatus(`Restoring ${NAMES[n] ?? n}…`) })
      if (!Object.keys(counts).length) throw new Error(failed.length ? failed.join(" ") : "That .zip has no notes in it. Choose a Nostr Vault notes backup.")
      const refused = Object.values(counts).reduce((n, c) => n + c.refused + c.bad, 0)
      setStatus(`Restored: ${summary(counts)}.` + (refused ? ` ${events(refused)} not restored: not this account's, or damaged.` : "") + (skipped.length ? ` Skipped ${skipped.join(", ")}.` : "") + (failed.length ? ` ${failed.join(" ")}` : ""))
    })()
  }
  // An older web backup: your own signed events, one per line, into your notes.
  const restoreLines = async text => {
    const { events: evs, skipped } = parseBackup(text, ctx.session.pubkey)
    const skippedText = Object.entries(skipped).filter(([, n]) => n).map(([k, n]) => `${n} ${SKIPPED[k]}`).join(", ")
    if (!evs.length) throw new Error(`That file has nothing to restore${skippedText ? ` (${skippedText})` : ""}. Choose a Nostr Vault backup.`)
    const r = await restoreBackup(ctx.vault, evs, { onProgress: p => setStatus(`Restoring ${p.done} of ${p.of}…`) })
    setStatus(`Restored: your notes ${r.stored}, already here ${r.duplicate}.` + (r.refused.length ? ` ${events(r.refused.length)} refused.` : "") + (skippedText ? ` Skipped ${skippedText}.` : ""))
  }
  return (
    <section class="card backup">
      <h3>Backup</h3>
      <p class="muted small">Your notes, private notes, messages and feed cache from this browser's relay, as a .zip. It's the same file the iPhone app makes in Settings › Backup, so either one restores the other. Photos and videos aren't in it. Restoring publishes nothing.</p>
      <div class="row">
        <button disabled={!!busy} onClick={doExport} aria-busy={busy === "export" || undefined}>{busy === "export" ? "Exporting…" : "Export notes"}</button>
        <label class={busy ? "button disabled" : "button"}>
          {busy === "import" ? "Restoring…" : "Import notes"}
          <input type="file" accept=".zip,application/zip,.jsonl,.ndjson,.json" disabled={!!busy} onChange={doImport} hidden />
        </label>
      </div>
      {status && <p class="muted small">{status}</p>}
      {err && <p class="error small">{err}</p>}
    </section>
  )
}
