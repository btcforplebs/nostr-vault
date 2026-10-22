// The Recipes feed (the iPhone's RecipeCardView grid and RecipeCategoryBar): Following or Global (your web of
// trust), category chips
// built from the recipes loaded, image tiles. A tile opens the recipe in the article reader, whose "Open in" link
// goes to zap.cooking. Strangers' recipes: held in memory only.
import { useEffect, useRef, useState } from "preact/hooks"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { visibleNotes } from "../net/blocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { ArticleReader, Scopes } from "./ArticlesScreen.jsx"
import { EmptyState } from "./EmptyState.jsx"
import { displayTitle, longFormLink, longFormMeta } from "./longform.js"
import { RECIPE_SCOPES, fetchRecipes, inCategory, loadScope, recipeCategories, saveScope } from "./recipes.js"
import { SkeletonGrid } from "../components/Loading.jsx"
import { followsDep, heldResults } from "./held.js"

if (import.meta.env) import("./readers.css")

const held = heldResults()

export function RecipesScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(loadScope)
  const [recipes, setRecipes] = useState(() => held.get(loadScope(), follows) ?? null)
  const [category, setCategory] = useState(null)
  const [status, setStatus] = useState("")
  const [failed, setFailed] = useState(false)
  const [open, setOpen] = useState(null)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)

  const load = async () => {
    const n = ++seq.current
    if (!follows.length) return setStatus("")
    if (navigator.onLine === false) return setStatus("Offline: Recipes needs the network")
    setStatus("Loading recipes…")
    setFailed(false)
    try {
      const got = await fetchRecipes({ scope, me: ctx.session?.pubkey, follows, readRelays: account.relays.read })
      if (n !== seq.current) return
      const list = got?.recipes ?? []
      held.set(scope, follows, list)
      setRecipes(list)
      setStatus("")
      if (list.length) fetchProfiles(vault, list.map(r => r.pubkey), account.relays.read, { save: false }).catch(() => {})
    } catch { if (n === seq.current) { setStatus(""); setFailed(true); setRecipes(r => r ?? []) } }
  }
  useEffect(() => { setOpen(null); setCategory(null); setRecipes(held.get(scope, follows) ?? null); if (!held.has(scope, follows)) load() }, [scope, followsDep(follows)])

  if (open) return <ArticleReader event={open} onBack={() => setOpen(null)} ctx={ctx} />
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
      {!follows.length ? <p class="empty">{!account.loaded ? "Loading your follows…" : scope === "following" ? "Follow someone to see their recipes here."
          : "Global shows recipes from people your web of trust vouches for. Follow a few people first."}</p>
        : recipes === null ? <SkeletonGrid count={6} gridClass="recipe-grid" tileClass="sk-recipe" label="Loading recipes…" />
        : !shown.length ? (recipes.length && !unblocked.length ? <p class="empty">Every recipe loaded here is from someone you blocked.</p>
          : recipes.length ? <p class="empty">No recipes in this category.</p>
          : <RecipesEmpty scope={scope} failed={failed} onGlobal={() => pick("global")} onRetry={load} />)
        : <div class="recipe-grid">{shown.map(r => <RecipeTile key={r.id} event={r} onOpen={() => setOpen(r)} />)}</div>}
    </div>
  )
}

/** The iPhone's empty Recipes: nothing from your follows (Show Global recipes), no relay answered, or nothing came. */
export function RecipesEmpty({ scope, failed, onGlobal, onRetry }) {
  if (scope === "following" && !failed) return <EmptyState title="No recipes from your follows" detail="Nobody you follow has posted a recipe. Switch to Global to see everyone's." action={{ label: "Show Global recipes", onClick: onGlobal }} />
  return failed
    ? <EmptyState title="Could not reach any relay" detail="Recipes come from other people's relays, so this one needs a connection." action={{ label: "Try again", onClick: onRetry }} />
    : <EmptyState title="No recipes found" detail="Nothing tagged zapcooking or nostrcooking came back." action={{ label: "Try again", onClick: onRetry }} />
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
