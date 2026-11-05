// New Highlight (parity #28): a passage you want to keep, with an optional page link and comment, published as a
// NIP-84 highlight (kind 9802) the way the iPhone's share sheet writes one (highlight.js). It goes out like a note,
// to your write relays; what isn't posted yet is kept as a draft, as the other kinds.
import { useEffect, useRef, useState } from "preact/hooks"
import { publishKind } from "../../net/sync.js"
import { Dialog } from "../../components/Moderation.jsx"
import { PostResult } from "./PostResult.jsx"
import { ComposeKinds } from "./ComposeKinds.jsx"
import { forgetIfSent, idbDrafts } from "./drafts.js"
import { HIGHLIGHT_KIND, LINK_HINT, LINK_LABEL, LINK_PLACEHOLDER, LINK_PROBLEM, checkLink, emptyHighlight, hasHighlight, highlightComplete, highlightTags } from "./highlight.js"

const DRAFT_KEY = "highlight"

export function HighlightCompose({ ctx }) {
  const [d, setD] = useState(emptyHighlight)
  const set = patch => setD(cur => ({ ...cur, ...patch }))
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [err, setErr] = useState("")
  const [leaving, setLeaving] = useState(false)

  const drafts = useRef(null)
  drafts.current ??= idbDrafts(ctx.session.pubkey)
  const [loaded, setLoaded] = useState(false)
  useEffect(() => {
    let live = true
    drafts.current.get(DRAFT_KEY).catch(() => null).then(saved => { if (!live) return; if (saved) setD({ ...emptyHighlight(), ...saved }); setLoaded(true) })
    return () => { live = false }
  }, [])
  const saving = useRef(Promise.resolve())
  useEffect(() => {
    if (!loaded) return
    saving.current = saving.current.then(() => (hasHighlight(d) ? drafts.current.put(DRAFT_KEY, d) : drafts.current.delete(DRAFT_KEY))).catch(() => {})
  }, [d, loaded])

  const link = checkLink(d.link)
  const canPost = !busy && highlightComplete(d)
  const post = async e => {
    e?.preventDefault()
    if (!canPost) return
    setErr(""); setResult(null); setBusy(true)
    try {
      const passage = d.passage.trim()
      const sent = await publishKind(ctx.vault, ctx.signer, ctx.session.pubkey, HIGHLIGHT_KIND, passage, ctx.account.relays.write,
        highlightTags({ passage, link, comment: d.comment }))
      setResult(sent)
      if (await forgetIfSent(sent, { stopSaving: () => setLoaded(false), clear: () => setD(emptyHighlight()), saving, drafts: drafts.current, key: DRAFT_KEY })) setLoaded(true)
      else setErr("Not sent to any relay. Your highlight is still here: try again.")
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const cancel = () => (hasHighlight(d) ? setLeaving(true) : history.back())
  const discard = async () => {
    await saving.current
    await drafts.current.delete(DRAFT_KEY).catch(() => {})
    setLoaded(false)
    setD(emptyHighlight()); setLeaving(false)
    history.back()
  }

  const label = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Posting…") : "Post"
  return (
    <main class="screen compose-sheet compose-highlight">
      <header class="compose-bar">
        <button type="button" class="compose-cancel" onClick={cancel}>Cancel</button>
        <h2 class="sr-only">New Highlight</h2>
        <button type="submit" form="highlight-form" class="compose-post" disabled={!canPost} aria-busy={busy || undefined}>{label}</button>
      </header>
      <ComposeKinds type="highlight" />
      <form id="highlight-form" class="kind-form" noValidate onSubmit={post}>
        <fieldset class="kind-group">
          <legend>Highlight</legend>
          <textarea class="kind-field highlight-passage" rows={5} placeholder="The words you want to keep" aria-label="Highlight" value={d.passage} readOnly={busy}
            onInput={e => set({ passage: e.currentTarget.value })} />
        </fieldset>
        <fieldset class="kind-group">
          <legend>Your thoughts (optional)</legend>
          <textarea class="kind-field" rows={2} placeholder="Add a comment" aria-label="Comment" value={d.comment} readOnly={busy}
            onInput={e => set({ comment: e.currentTarget.value })} />
        </fieldset>
        <fieldset class="kind-group">
          <legend>{LINK_LABEL}</legend>
          <input type="text" inputmode="url" class="kind-field" placeholder={LINK_PLACEHOLDER} aria-label={LINK_LABEL} value={d.link} readOnly={busy}
            autocapitalize="off" autocorrect="off" spellcheck={false} onInput={e => set({ link: e.currentTarget.value })} />
          <p class={link === null ? "small kind-note error" : "muted small kind-note"} role="status">{link === null ? LINK_PROBLEM : LINK_HINT}</p>
        </fieldset>
        <p class="muted small kind-note">Highlights are public.</p>
        {loaded && hasHighlight(d) && !result && <p class="muted small kind-note">Draft saved</p>}
      </form>
      {leaving && (
        <Dialog label="Save this highlight as a draft?" onClose={() => setLeaving(false)}>
          <h3>Save this highlight as a draft?</h3>
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
