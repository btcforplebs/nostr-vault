// New Recipe: a NIP-23 long-form post (kind 30023) in zap.cooking's shape, as the iPhone writes one
// (Views/LongFormComposeView.swift, recipe flavor): a cover photo, a title, a short description, prep / cook time and
// servings, ingredients and directions one per line, chef's notes and categories. Write / Preview shows the post as it
// will go out. What isn't published yet is kept as a draft.
import { useEffect, useRef, useState } from "preact/hooks"
import { publishKind } from "../../net/sync.js"
import { Markdown } from "../../readers/Markdown.jsx"
import { Dialog } from "../../components/Moderation.jsx"
import { PostResult } from "./PostResult.jsx"
import { ComposeKinds } from "./ComposeKinds.jsx"
import { CoverPicker, useCover } from "./CoverPicker.jsx"
import { forgetIfSent, idbDrafts } from "./drafts.js"
import { EMPTY_RECIPE, LONG_FORM_KIND, buildRecipe, canPublishRecipe, hasRecipe, recipeContent, recipeDraftOf, recipeFromDraft, recipeHint } from "./recipe.js"

if (import.meta.env) import("../../readers/readers.css")

const DRAFT_KEY = "recipe"

export function RecipeCompose({ ctx }) {
  const [r, setR] = useState(EMPTY_RECIPE)
  const set = patch => setR(cur => ({ ...cur, ...patch }))
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
      if (d) setR(recipeFromDraft(d))
      setLoaded(true)
    })
    return () => { live = false }
  }, [])
  const saving = useRef(Promise.resolve())
  const kept = JSON.stringify(recipeDraftOf(r))
  useEffect(() => {
    if (!loaded) return
    const d = JSON.parse(kept)
    saving.current = saving.current.then(() => (hasRecipe(r) ? drafts.current.put(DRAFT_KEY, d) : drafts.current.delete(DRAFT_KEY))).catch(() => {})
  }, [kept, loaded])

  const covers = useCover(ctx, c => set({ cover: c }), () => setErr(""))
  const uploading = r.cover?.status === "uploading"
  const canPost = !busy && !uploading && canPublishRecipe(r)
  const hint = uploading ? null : recipeHint(r)

  const publish = async e => {
    e?.preventDefault()
    if (!canPost) return
    setErr(""); setResult(null); setBusy(true)
    try {
      const { content, tags } = buildRecipe({ ...r, cover: r.cover?.status === "done" ? r.cover : null })
      const sent = await publishKind(ctx.vault, ctx.signer, ctx.session.pubkey, LONG_FORM_KIND, content, ctx.account.relays.write, tags)
      setResult(sent)
      // Sent: the form and its draft are cleared first (drafts.js forgetIfSent). No relay took it: the recipe stays.
      const clear = () => { if (r.cover?.preview?.startsWith("blob:")) URL.revokeObjectURL(r.cover.preview); setR(EMPTY_RECIPE); setPreviewing(false) }
      if (await forgetIfSent(sent, { stopSaving: () => setLoaded(false), clear, saving, drafts: drafts.current, key: DRAFT_KEY })) setLoaded(true)
      else setErr("Not sent to any relay. Your recipe is still here: try again.")
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const cancel = () => (hasRecipe(r) ? setLeaving(true) : history.back())
  const discard = async () => {
    await saving.current
    await drafts.current.delete(DRAFT_KEY).catch(() => {})
    setLoaded(false) // so the cleared form isn't saved back over it
    setR(EMPTY_RECIPE); setLeaving(false)
    history.back()
  }

  const field = (key, props) => ({ value: r[key], readOnly: busy, onInput: e => set({ [key]: e.currentTarget.value }), ...props })
  const label = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Publishing…") : uploading ? "Uploading…" : "Publish"
  return (
    <main class="screen compose-sheet compose-article compose-recipe">
      <header class="compose-bar">
        <button type="button" class="compose-cancel" onClick={cancel}>Cancel</button>
        <h2>New Recipe</h2>
        <button type="submit" form="recipe-form" class="compose-post" disabled={!canPost} aria-busy={busy || uploading || undefined}>{label}</button>
      </header>
      <ComposeKinds type="recipe" />
      <form id="recipe-form" class="kind-form" onSubmit={publish}>
        <CoverPicker cover={r.cover} busy={busy} onPick={covers.pick} onRemove={() => covers.remove(r.cover)} />
        <input class="kind-title" type="text" placeholder="Title" aria-label="Title" {...field("title")} />
        <textarea class="kind-field" rows={2} placeholder="Short description" aria-label="Short description" {...field("summary")} />
        <div class="seg-pill kind-mode" role="radiogroup" aria-label="Mode">
          <button type="button" role="radio" aria-checked={!previewing} class={previewing ? "" : "on"} onClick={() => setPreviewing(false)}>Write</button>
          <button type="button" role="radio" aria-checked={previewing} class={previewing ? "on" : ""} onClick={() => setPreviewing(true)}>Preview</button>
        </div>
        {previewing
          ? <article class="article-preview" aria-label="Preview">
              {r.cover?.preview && <img class="article-preview-cover" src={r.cover.preview} alt="" />}
              <h1>{r.title.trim() || <span class="muted">Untitled</span>}</h1>
              {r.summary.trim() && <p class="article-preview-summary">{r.summary.trim()}</p>}
              <Markdown body={recipeContent(r)} />
            </article>
          : <>
              <fieldset class="kind-group">
                <legend>Details</legend>
                <input class="kind-field" type="text" placeholder="Prep time, e.g. 15 min" aria-label="Prep time" {...field("prepTime")} />
                <input class="kind-field" type="text" placeholder="Cook time, e.g. 30 min" aria-label="Cook time" {...field("cookTime")} />
                <input class="kind-field" type="text" inputmode="numeric" placeholder="Servings" aria-label="Servings" {...field("servings")} />
              </fieldset>
              <fieldset class="kind-group">
                <legend>Ingredients</legend>
                <textarea class="kind-field" rows={5} placeholder={"2 eggs\n1 cup flour"} aria-label="Ingredients" {...field("ingredients")} />
                <p class="muted small kind-note">One per line.</p>
              </fieldset>
              <fieldset class="kind-group">
                <legend>Directions</legend>
                <textarea class="kind-field" rows={6} placeholder={"Preheat the oven to 350°F\nWhisk the eggs"} aria-label="Directions" {...field("directions")} />
                <p class="muted small kind-note">One step per line. They get numbered for you.</p>
              </fieldset>
              <fieldset class="kind-group">
                <legend>Chef's notes (optional)</legend>
                <textarea class="kind-field" rows={3} aria-label="Chef's notes" {...field("body")} />
              </fieldset>
              <fieldset class="kind-group">
                <legend>Categories</legend>
                <input class="kind-field" type="text" placeholder="e.g. dinner, vegetarian, dessert" aria-label="Categories" {...field("categories")} />
                <p class="muted small kind-note">Comma separated.</p>
              </fieldset>
            </>}
        {hint && <p class="muted small kind-note" role="status">{hint}</p>}
        {loaded && hasRecipe(r) && !result && <p class="muted small kind-note">Draft saved</p>}
      </form>
      {leaving && (
        <Dialog label="Save this recipe as a draft?" onClose={() => setLeaving(false)}>
          <h3>Save this recipe as a draft?</h3>
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
