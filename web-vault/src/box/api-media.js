// Box API, Media area (One Vault spec E6/W5): Auto-Mirror and Copy to servers, run by the box's engine. Shapes
// (haven-go/internal/box/routes_media.go, auto_mirror.go, media_copy_job.go):
//   GET  media/auto-mirror      -> { enabled, runNowAt, state: { running, last_start, last_finish, last: { saved,
//                                    skipped, unreachable: [host], cap_reached, error } } | null }   any signed-in account
//   PUT  media/auto-mirror      { enabled } -> same                                                  first account only
//   POST media/auto-mirror/run  -> same; 409 while Auto-Mirror is off                                any signed-in account
//   POST media/copy/check       -> { id }   which of my files each of my servers lacks               my own files only
//   POST media/copy             { auths: ["Nostr <base64 kind 24242>"] } -> { id }
//   GET  media/copy             -> { queued, state: { id, action, running, servers, checked, files: [{ sha256, absent,
//                                    status: waiting|copied|failed, reasons: { server: why } }], copied, failed, error } | null }
// The box holds no account key, so the browser signs the uploads: one kind 24242 per 25 files, as the Mac does
// (MediaServersModel.filesPerSignature), each naming its files in x tags, good for an hour. The box only carries them.
import { nip98Header } from "./api.js"
import { boxApiBase } from "./mode.js"
import { authHeader } from "../net/upload.js"
import { checkSigned } from "../net/sync.js"

export const FILES_PER_SIGNATURE = 25

/** One upload authorisation for up to 25 files, good for an hour (the box refuses one longer than two). */
export const copyAuthTemplate = (hashes, at = Math.floor(Date.now() / 1000)) => ({
  kind: 24242, created_at: at, content: `Upload ${hashes.length} blob${hashes.length === 1 ? "" : "s"}`,
  tags: [["t", "upload"], ...hashes.map(x => ["x", x]), ["expiration", String(at + 3600)]],
})

/** `hashes` in batches of 25. */
export const batches = (hashes, size = FILES_PER_SIGNATURE) =>
  Array.from({ length: Math.ceil(hashes.length / size) }, (_, i) => hashes.slice(i * size, (i + 1) * size))

/** Signs one auth per batch, one signer call each (a remote signer may ask for every one). Each comes back checked:
 *  the signed-in account, the exact template (kind 24242 only, never a list), a good signature. */
export async function signCopyAuths(ctx, hashes) {
  const out = []
  for (const batch of batches(hashes)) {
    const t = copyAuthTemplate(batch)
    out.push(authHeader(checkSigned(await ctx.signer.signEvent(t), t, ctx.session.pubkey)))
  }
  return out
}

/** `signer`: the signed-in account's ({ signEvent }); `fetchImpl`: fetch (a mock in tests). */
export function mediaApi({ signer, base = boxApiBase(), fetchImpl = (...a) => fetch(...a) }) {
  const call = async (method, name, payload) => {
    if (!signer?.signEvent || signer.readOnly) throw new Error("Sign in with your account's signer to use the box.")
    const url = `${base}/${name}`
    const body = payload ? JSON.stringify(payload) : undefined
    const headers = { Authorization: await nip98Header(signer, url, method, payload) }
    if (body) headers["Content-Type"] = "application/json"
    const res = await fetchImpl(url, { method, headers, body })
    const text = await res.text()
    let data = null
    try { data = text ? JSON.parse(text) : null } catch {}
    if (!res.ok) {
      const said = data?.message || data?.error
      const e = new Error(res.status === 403 ? "Only the box's first account can change this."
        : said ? said[0].toUpperCase() + said.slice(1) : `The box answered ${res.status}`)
      e.status = res.status
      throw e
    }
    return data ?? {}
  }
  return {
    autoMirror: () => call("GET", "media/auto-mirror"),
    setAutoMirror: enabled => call("PUT", "media/auto-mirror", { enabled: !!enabled }),
    runAutoMirror: () => call("POST", "media/auto-mirror/run", {}),
    checkCopy: () => call("POST", "media/copy/check", {}),
    copy: auths => call("POST", "media/copy", { auths }),
    copyState: () => call("GET", "media/copy"),
  }
}

/** The last Auto-Mirror run in words, or "" before the first. */
export function lastRunLine(view, now = Date.now()) {
  const st = view?.state
  if (st?.running) return "Copying in now…"
  const last = st?.last
  if (!last || !st.last_finish) return ""
  const ago = Math.max(0, Math.round((now / 1000 - st.last_finish) / 60))
  const when = ago < 1 ? "just now" : ago < 60 ? `${ago} min ago` : `${Math.round(ago / 60)} h ago`
  const parts = [last.saved === 0 ? "nothing new" : `${last.saved} new file${last.saved === 1 ? "" : "s"}`]
  if (last.skipped) parts.push(`${last.skipped} skipped`)
  if (last.cap_reached) parts.push("more next run")
  if (last.unreachable?.length) parts.push(`couldn't read ${last.unreachable.join(", ")}`)
  return `Last run ${when}: ${parts.join(", ")}.`
}
