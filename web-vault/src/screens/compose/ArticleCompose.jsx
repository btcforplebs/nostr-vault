// New Article: a NIP-23 long-form post (kind 30023), as the iPhone writes one (Views/LongFormComposeView.swift):
// a cover photo, a title, an optional summary, and a Markdown body with Write / Preview. The cover goes up to the
// account's media servers when it's picked; what isn't published yet is kept as a draft.
import { useEffect, useRef, useState } from "preact/hooks"
import { publishKind } from "../../net/sync.js"
import { mediaServers, uploadPhoto } from "../../net/upload.js"
import { Markdown } from "../../readers/Markdown.jsx"
import { Dialog } from "../../components/Moderation.jsx"
import { PostResult } from "./PostResult.jsx"
import { ComposeKinds } from "./ComposeKinds.jsx"
import { idbDrafts } from "./drafts.js"
import { LONG_FORM_KIND, articleDraftOf, articleHint, buildArticle, canPublishArticle, hasArticle } from "./article.js"

if (import.meta.env) import("../../readers/readers.css")

const DRAFT_KEY = "article"
const EMPTY = { title: "", summary: "", body: "", cover: null }

export function ArticleCompose({ ctx }) {
  const [a, setA] = useState(EMPTY) // cover: { preview, status: "uploading" | "done" | "failed", url?, error? }
  const set = patch => setA(cur => ({ ...cur, ...patch }))
  const [previewing, setPreviewing] = useState(false)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [err, setErr] = useState("")
  const [leaving, setLeaving] = useState(false)

  // The draft: loaded once, then saved on every change, one write after another.
  const drafts = useRef(null)
  drafts.current ??= idbDrafts(ctx.session.pubkey)
  const [loaded, setLoaded] = useState(false)
  useEffect(() => {
    let live = true
    drafts.current.get(DRAFT_KEY).catch(() => null).then(d => {
      if (!live) return
      if (d) setA({ title: d.title ?? "", summary: d.summary ?? "", body: d.body ?? "", cover: d.cover?.url ? { ...d.cover, preview: d.cover.url, status: "done" } : null })
      setLoaded(true)
    })
    return () => { live = false }
  }, [])
  const saving = useRef(Promise.resolve())
  useEffect(() => {
    if (!loaded) return
    const d = articleDraftOf(a)
    saving.current = saving.current.then(() => (hasArticle(a) ? drafts.current.put(DRAFT_KEY, d) : drafts.current.delete(DRAFT_KEY))).catch(() => {})
  }, [a.title, a.summary, a.body, a.cover?.url, loaded])

  // The cover: one photo, uploaded as soon as it's picked. A newer pick wins over one still uploading.
  const picker = useRef(null)
  const pickNo = useRef(0)
  const pickCover = async file => {
    if (!file || !/^image\//.test(file.type)) return
    const no = ++pickNo.current
    const preview = URL.createObjectURL(file)
    set({ cover: { preview, status: "uploading", file } }); setErr("")
    try {
      const up = await uploadPhoto(file, { ctx, servers: await mediaServers(ctx) })
      if (no === pickNo.current) set({ cover: { ...up, preview, status: "done" } })
    } catch (e) {
      if (no === pickNo.current) set({ cover: { preview, status: "failed", file, error: String(e?.message ?? e) } })
    }
  }
  const removeCover = () => {
    pickNo.current++
    if (a.cover?.preview?.startsWith("blob:")) URL.revokeObjectURL(a.cover.preview)
    set({ cover: null })
  }

  const uploading = a.cover?.status === "uploading"
  const canPost = !busy && !uploading && canPublishArticle(a)
  const hint = uploading ? null : articleHint(a)

  const publish = async e => {
    e?.preventDefault()
    if (!canPost) return
    setErr(""); setResult(null); setBusy(true)
    try {
      const cover = a.cover?.status === "done" ? a.cover : null
      const { content, tags } = buildArticle({ ...a, cover })
      setResult(await publishKind(ctx.vault, ctx.signer, ctx.session.pubkey, LONG_FORM_KIND, content, ctx.account.relays.write, tags))
      setA(EMPTY); setPreviewing(false)
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const cancel = () => (hasArticle(a) ? setLeaving(true) : history.back())
  const discard = async () => {
    await saving.current
    await drafts.current.delete(DRAFT_KEY).catch(() => {})
    setLoaded(false) // so the cleared form isn't saved back over it
    setA(EMPTY); setLeaving(false)
    history.back()
  }

  const label = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Publishing…") : uploading ? "Uploading…" : "Publish"
  return (
    <main class="screen compose-sheet compose-article">
      <header class="compose-bar">
        <button type="button" class="compose-cancel" onClick={cancel}>Cancel</button>
        <h2>New Article</h2>
        <button type="submit" form="article-form" class="compose-post" disabled={!canPost} aria-busy={busy || uploading || undefined}>{label}</button>
      </header>
      <ComposeKinds type="article" />
      <form id="article-form" class="kind-form" onSubmit={publish}>
        <div class={a.cover ? `article-cover has ${a.cover.status}` : "article-cover"}>
          <button type="button" class="article-cover-pick" disabled={busy} onClick={() => picker.current.click()}
            aria-label={a.cover ? "Change cover photo" : "Add a cover photo"}>
            {a.cover
              ? <img src={a.cover.preview} alt="" />
              : <span class="article-cover-empty">
                  <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2.5" /><circle cx="9" cy="10" r="1.6" /><path d="M21 16l-5-5-8 8" /></svg>
                  Add a cover photo
                </span>}
          </button>
          {uploading && <span class="article-cover-state" role="status">Uploading…</span>}
          {a.cover?.status === "failed" && <span class="article-cover-state">Didn't upload</span>}
          {a.cover && !busy && <button type="button" class="article-cover-remove" aria-label="Remove cover photo" onClick={removeCover}>
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
          </button>}
          <input ref={picker} type="file" accept="image/*" hidden onChange={e => { pickCover(e.currentTarget.files?.[0]); e.currentTarget.value = "" }} />
        </div>
        {a.cover?.status === "failed" && <p class="error small">{a.cover.error} <button type="button" class="small" onClick={() => pickCover(a.cover.file)}>Retry</button></p>}
        <input class="kind-title" type="text" placeholder="Title" aria-label="Title" value={a.title} readOnly={busy}
          onInput={e => set({ title: e.currentTarget.value })} />
        <textarea class="kind-field" rows={2} placeholder="Summary (optional)" aria-label="Summary" value={a.summary} readOnly={busy}
          onInput={e => set({ summary: e.currentTarget.value })} />
        <div class="seg-pill kind-mode" role="radiogroup" aria-label="Mode">
          <button type="button" role="radio" aria-checked={!previewing} class={previewing ? "" : "on"} onClick={() => setPreviewing(false)}>Write</button>
          <button type="button" role="radio" aria-checked={previewing} class={previewing ? "on" : ""} onClick={() => setPreviewing(true)}>Preview</button>
        </div>
        {previewing
          ? <article class="article-preview" aria-label="Preview">
              {a.cover?.preview && <img class="article-preview-cover" src={a.cover.preview} alt="" />}
              <h1>{a.title.trim() || <span class="muted">Untitled</span>}</h1>
              {a.summary.trim() && <p class="article-preview-summary">{a.summary.trim()}</p>}
              {a.body.trim() ? <Markdown body={a.body} /> : <p class="muted">Nothing written yet.</p>}
            </article>
          : <>
              <textarea class="kind-field article-body" rows={14} placeholder="Write your article…" aria-label="Article" value={a.body} readOnly={busy}
                onInput={e => set({ body: e.currentTarget.value })} />
              <p class="muted small kind-note">Markdown works: # headings, **bold**, - lists, &gt; quotes. Preview shows how it reads.</p>
            </>}
        {hint && <p class="muted small kind-note" role="status">{hint}</p>}
        {loaded && hasArticle(a) && !result && <p class="muted small kind-note">Draft saved</p>}
      </form>
      {leaving && (
        <Dialog label="Save this article as a draft?" onClose={() => setLeaving(false)}>
          <h3>Save this article as a draft?</h3>
          <p class="muted small">Drafts stay in this browser.</p>
          <div class="mod-row compose-leave">
            <button type="button" class="primary" onClick={() => { setLeaving(false); history.back() }}>Save Draft</button>
            <button type="button" class="danger" onClick={discard}>Discard</button>
            <button type="button" onClick={() => setLeaving(false)}>Keep Editing</button>
          </div>
        </Dialog>
      )}
      {err && <p class="error">{err}</p>}
      {result && <PostResult result={result} />}
    </main>
  )
}
