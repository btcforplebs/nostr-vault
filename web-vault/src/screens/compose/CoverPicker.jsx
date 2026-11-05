// A long-form post's cover photo (New Article, New Recipe): one photo, uploaded to the account's media servers as soon
// as it's picked. A newer pick wins over one still uploading.
import { useRef } from "preact/hooks"
import { mediaServers, uploadPhoto } from "../../net/upload.js"

/** cover: { preview, status: "uploading" | "done" | "failed", url?, error?, file? } or null; `setCover` sets it. */
export function useCover(ctx, setCover, onPick = () => {}) {
  const pickNo = useRef(0)
  const pick = async file => {
    if (!file || !/^image\//.test(file.type)) return
    const no = ++pickNo.current
    const preview = URL.createObjectURL(file)
    setCover({ preview, status: "uploading", file }); onPick()
    try {
      const up = await uploadPhoto(file, { ctx, servers: await mediaServers(ctx) })
      if (no === pickNo.current) setCover({ ...up, preview, status: "done" })
    } catch (e) {
      if (no === pickNo.current) setCover({ preview, status: "failed", file, error: String(e?.message ?? e) })
    }
  }
  const remove = cover => {
    pickNo.current++
    if (cover?.preview?.startsWith("blob:")) URL.revokeObjectURL(cover.preview)
    setCover(null)
  }
  return { pick, remove }
}

export function CoverPicker({ cover, busy, onPick, onRemove }) {
  const picker = useRef(null)
  return (
    <>
      <div class={cover ? `article-cover has ${cover.status}` : "article-cover"}>
        <button type="button" class="article-cover-pick" disabled={busy} onClick={() => picker.current.click()}
          aria-label={cover ? "Change cover photo" : "Add a cover photo"}>
          {cover
            ? <img src={cover.preview} alt="" />
            : <span class="article-cover-empty">
                <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2.5" /><circle cx="9" cy="10" r="1.6" /><path d="M21 16l-5-5-8 8" /></svg>
                Add a cover photo
              </span>}
        </button>
        {cover?.status === "uploading" && <span class="article-cover-state" role="status">Uploading…</span>}
        {cover?.status === "failed" && <span class="article-cover-state">Didn't upload</span>}
        {cover && !busy && <button type="button" class="article-cover-remove" aria-label="Remove cover photo" onClick={onRemove}>
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>}
        <input ref={picker} type="file" accept="image/*" hidden onChange={e => { onPick(e.currentTarget.files?.[0]); e.currentTarget.value = "" }} />
      </div>
      {cover?.status === "failed" && <p class="error small">{cover.error} <button type="button" class="small" onClick={() => onPick(cover.file)}>Retry</button></p>}
    </>
  )
}
