// Upload in Vault › Media (the iPhone's gallery Upload: Photos, Videos, Files): pick photos or videos and each goes to
// the first of your media servers that takes it, through the same signed upload as a note's photo (net/upload.js
// uploadPhoto, one kind 24242 authorisation per file). Copying a file to your other servers stays in its viewer. Not
// offered when signed in read-only.
import { useRef, useState } from "preact/hooks"
import { megabytes, uploadPhoto } from "../net/upload.js"
import { mediaType } from "../net/blossom-gallery.js"

const hostOf = url => { try { return new URL(url).host } catch { return url } }

/** The largest file the page will read: a file is read whole into memory to hash it, so a multi-GB video would take
 *  the tab down (Tron, #938). 100 MB is also about what public Blossom servers take. iOS has no such cap. */
export const MAX_UPLOAD_BYTES = 100_000_000

/** Uploads `files` one at a time; one over MAX_UPLOAD_BYTES is skipped unread, with its own line. -> { added: [blob], errors: [string] }. `upload` is for tests. */
export async function uploadFiles(files, { ctx, servers, upload = uploadPhoto, now = () => Math.floor(Date.now() / 1000) }) {
  const added = [], errors = []
  for (const file of files) {
    if (file.size > MAX_UPLOAD_BYTES) { errors.push(`${file.name || "A file"}: ${megabytes(file.size)} is over the ${megabytes(MAX_UPLOAD_BYTES)} limit for uploads from the browser.`); continue }
    try {
      const r = await upload(file, { ctx, servers })
      added.push({ sha256: r.sha256, url: r.url, type: r.mime, size: r.size, uploaded: now(), kind: mediaType({ type: r.mime, url: r.url }), servers: [r.server] })
    } catch (e) { errors.push(`${file.name || "A file"}: ${e?.message ?? e}`) }
  }
  return { added, errors }
}

/** What happened, in a line. */
export function uploadNote({ added, errors }, servers) {
  const parts = []
  if (added.length) {
    const hosts = [...new Set(added.flatMap(b => b.servers).map(hostOf))].join(", ")
    parts.push(`Uploaded ${added.length === 1 ? "1 file" : `${added.length} files`} to ${hosts}.${servers.length > 1 ? " Open one to copy it to your other servers." : ""}`)
  }
  if (errors.length) parts.push(errors.join(" · "))
  return parts.join(" ")
}

export function BlossomUpload({ ctx, servers, onAdded }) {
  if (ctx.signer?.readOnly || !servers.length) return null
  return <UploadButton ctx={ctx} servers={servers} onAdded={onAdded} />
}

function UploadButton({ ctx, servers, onAdded }) {
  const input = useRef(null)
  const [busy, setBusy] = useState("")
  const [note, setNote] = useState("")
  const pick = async e => {
    const files = [...(e.currentTarget.files ?? [])]
    e.currentTarget.value = ""
    if (!files.length) return
    setNote("")
    setBusy(files.length === 1 ? "Uploading…" : `Uploading ${files.length} files…`)
    const r = await uploadFiles(files, { ctx, servers })
    setBusy("")
    if (r.added.length) onAdded(r.added)
    setNote(uploadNote(r, servers))
  }
  return (
    <div class="status-line" style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
      <input ref={input} type="file" accept="image/*,video/*" multiple hidden onChange={pick} />
      <button type="button" class="small" disabled={!!busy} onClick={() => input.current?.click()} aria-busy={!!busy || undefined}>{busy || "Upload photos or videos"}</button>
      {note && <span role="status">{note}</span>}
    </div>
  )
}
