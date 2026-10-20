// The Recipes feed (the iPhone's RecipeCardView grid and RecipeCategoryBar): Following or Global, category chips
// built from the recipes loaded, image tiles. A tile opens the recipe in the article reader, whose "Open in" link
// goes to zap.cooking. Strangers' recipes: held in memory only.
import { useEffect, useRef, useState } from "preact/hooks"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { visibleNotes } from "../net/blocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { ArticleReader, Scopes } from "./ArticlesScreen.jsx"
import { displayTitle, longFormLink, longFormMeta } from "./longform.js"
import { RECIPE_SCOPES, fetchRecipes, inCategory, loadScope, recipeCategories, saveScope } from "./recipes.js"

if (import.meta.env) import("./readers.css")

// Loaded recipes by scope, for this session, so switching feeds and back shows them at once (memory only).
const held = new Map()

export function RecipesScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(loadScope)
  const [recipes, setRecipes] = useState(() => held.get(loadScope()) ?? null)
  const [category, setCategory] = useState(null)
  const [status, setStatus] = useState("")
  const [open, setOpen] = useState(null)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)

  const load = async () => {
    const n = ++seq.current
    if (scope === "following" && !follows.length) return setStatus("")
    if (navigator.onLine === false) return setStatus("Offline: Recipes needs the network")
    setStatus("Loading recipes…")
    try {
      const list = await fetchRecipes({ scope, follows, readRelays: account.relays.read })
      if (n !== seq.current) return
      held.set(scope, list ?? [])
      setRecipes(list ?? [])
      setStatus("")
      if (list?.length) fetchProfiles(vault, list.map(r => r.pubkey), account.relays.read, { save: false }).catch(() => {})
    } catch (e) { if (n === seq.current) setStatus(`Couldn't load (${e?.message ?? e})`) }
  }
  useEffect(() => { setOpen(null); setCategory(null); setRecipes(held.get(scope) ?? null); if (!held.has(scope)) load() }, [scope, follows.length])

  if (open) return <ArticleReader event={open} onBack={() => setOpen(null)} />
  const pick = s => { saveScope(s); setScope(s) }
  const unblocked = recipes && visibleNotes(recipes, blocked)
  const chips = unblocked ? recipeCategories(unblocked) : []
  const shown = unblocked && inCategory(unblocked, category)
  return (
    <div class="reader-feed">
      <Scopes scopes={RECIPE_SCOPES} value={scope} onPick={pick} onRefresh={load} />
      {chips.length > 0 && (
        <div class="reader-chips" role="tablist" aria-label="Category">
          <button type="button" class={category === null ? "on" : ""} aria-selected={category === null} onClick={() => setCategory(null)}>All</button>
          {chips.map(c => <button key={c} type="button" class={category === c ? "on" : ""} aria-selected={category === c} onClick={() => setCategory(category === c ? null : c)}>{cap(c)}</button>)}
        </div>
      )}
      {status && <div class="status-line">{status}</div>}
      {scope === "following" && !follows.length ? <p class="empty">{account.loaded ? "Follow someone to see their recipes here, or switch to Global." : "Loading your follows…"}</p>
        : recipes === null ? <p class="empty">Loading recipes…</p>
        : !shown.length ? <p class="empty">{recipes.length && !unblocked.length ? "Every recipe loaded here is from someone you blocked."
          : scope === "following" ? "Nobody you follow has posted a recipe yet. Try Global." : "No recipes found."}</p>
        : <div class="recipe-grid">{shown.map(r => <RecipeTile key={r.id} event={r} onOpen={() => setOpen(r)} />)}</div>}
    </div>
  )
}

const cap = s => s.charAt(0).toUpperCase() + s.slice(1)

/** One tile: the hero image (most zap.cooking recipes have one), the title in two lines, the author. A click opens
 *  the reader; the title is also a real link to zap.cooking, so right-click or middle-click opens it there (the
 *  iPhone's long-press "Open in zap.cooking"). */
export function RecipeTile({ event, onOpen }) {
  const { image } = longFormMeta(event)
  const link = longFormLink(event)
  return (
    <article class="recipe-tile" tabindex="0" onClick={onOpen} onKeyDown={e => { if (e.key === "Enter") onOpen() }}>
      {image ? <img src={image} alt="" loading="lazy" referrerpolicy="no-referrer" /> : <div class="recipe-blank" aria-hidden="true">🍴</div>}
      <div class="recipe-text">
        <h3>{link ? <a href={link.url} target="_blank" rel="noopener noreferrer" onClick={e => { e.preventDefault(); e.stopPropagation(); onOpen() }}>{displayTitle(event)}</a> : displayTitle(event)}</h3>
        <span class="muted small"><AuthorName pubkey={event.pubkey} /></span>
      </div>
    </article>
  )
}
