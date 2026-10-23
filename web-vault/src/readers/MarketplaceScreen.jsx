// The Marketplace (the iPhone's MarketplaceCardView grid, MarketplaceCategoryBar and MarketplaceListingSheet):
// Global (sellers your web of trust vouches for) or Following, category chips for the categories present, square tiles with price and an auction badge.
// A tile opens the listing: photos, price, category and location, description, the seller, and Buy (or Bid) on
// Plebeian. Nothing is stored. Messaging a seller signs a DM, so it is not here yet.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { Scopes } from "./ArticlesScreen.jsx"
import { EmptyState } from "./EmptyState.jsx"
import { MARKET_SCOPES, fetchListings, loadScope, marketCategories, plebeianUrl, priceLabel, saveScope } from "./market.js"
import { SkeletonGrid } from "../components/Loading.jsx"
import { followsDep, heldResults } from "./held.js"

if (import.meta.env) import("./readers.css")

const held = heldResults()

export function MarketplaceScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(loadScope)
  const [listings, setListings] = useState(() => held.get(loadScope(), follows) ?? null)
  const [category, setCategory] = useState(null)
  const [status, setStatus] = useState("")
  const [open, setOpen] = useState(null)
  const [failed, setFailed] = useState(false)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)

  const load = async () => {
    const n = ++seq.current
    if (!follows.length) return setStatus("")
    if (navigator.onLine === false) return setStatus("Offline: the Marketplace needs the network")
    setStatus("Loading listings…")
    setFailed(false)
    try {
      const got = await fetchListings({ scope, me: ctx.session?.pubkey, follows, blocked })
      if (n !== seq.current) return
      const list = got?.listings ?? []
      held.set(scope, follows, list)
      setListings(list)
      setStatus("")
      if (list?.length) fetchProfiles(vault, list.map(l => l.pubkey), account.relays.read, { save: false }).catch(() => {})
    } catch { if (n === seq.current) { setStatus(""); setFailed(true); setListings(l => l ?? []) } }
  }
  useEffect(() => { setOpen(null); setCategory(null); setListings(held.get(scope, follows) ?? null); if (!held.has(scope, follows)) load() }, [scope, followsDep(follows)])

  if (open) return <ListingView ctx={ctx} listing={open} onBack={() => setOpen(null)} />
  const pick = s => { saveScope(s); setScope(s) }
  const unblocked = listings?.filter(l => !blocked.has(l.pubkey))
  const cats = unblocked ? marketCategories(unblocked) : []
  const shown = unblocked && (category && cats.includes(category) ? unblocked.filter(l => l.category === category) : unblocked)
  return (
    <div class="reader-feed">
      <Scopes scopes={MARKET_SCOPES} value={scope} onPick={pick} onRefresh={load} />
      {cats.length > 0 && (
        <div class="reader-chips" role="tablist" aria-label="Category">
          <button type="button" class={!category ? "on" : ""} aria-selected={!category} onClick={() => setCategory(null)}>All</button>
          {cats.map(c => <button key={c} type="button" class={category === c ? "on" : ""} aria-selected={category === c} onClick={() => setCategory(category === c ? null : c)}>{c}</button>)}
        </div>
      )}
      {status && listings !== null && <div class="status-line">{status}</div>}
      {!follows.length ? <p class="empty">{!account.loaded ? "Loading your follows…" : scope === "following" ? "Follow someone to see what they sell, or switch to Global."
          : "Global shows sellers your web of trust vouches for. Follow a few people first."}</p>
        : listings === null ? <SkeletonGrid count={6} gridClass="market-grid" tileClass="sk-card" label="Loading listings…" />
        : !shown.length ? (listings.length && !unblocked.length ? <p class="empty">Every listing loaded here is from someone you blocked.</p>
          : <MarketEmpty scope={scope} failed={failed} onGlobal={() => pick("global")} onRetry={load} />)
        : <div class="market-grid">{shown.map(l => <MarketTile key={l.id} listing={l} onOpen={() => setOpen(l)} />)}</div>}
    </div>
  )
}

/** The iPhone's empty Marketplace: nothing from your follows (Show Global listings), no relay answered, or nothing came. */
export function MarketEmpty({ scope, failed, onGlobal, onRetry }) {
  if (scope === "following") return <EmptyState title="No listings from your follows" detail="Nobody you follow is selling anything. Switch to Global to see every listing." action={{ label: "Show Global listings", onClick: onGlobal }} />
  return failed
    ? <EmptyState title="Could not reach any relay" detail="Listings come from other people's relays, so this one needs a connection." action={{ label: "Try again", onClick: onRetry }} />
    : <EmptyState title="No listings found" detail="No products, auctions or classifieds with a photo came back." action={{ label: "Try again", onClick: onRetry }} />
}

/** A square photo, the title, the price and the seller; an auction says so. */
export function MarketTile({ listing: l, onOpen }) {
  return (
    <article class="market-tile" tabindex="0" onClick={onOpen} onKeyDown={e => { if (e.key === "Enter") onOpen() }} aria-label={`${l.title}, ${priceLabel(l)}${l.isAuction ? ", auction" : ""}`}>
      <div class="market-photo"><img src={l.images[0]} alt="" loading="lazy" referrerpolicy="no-referrer" />{l.isAuction && <span class="market-badge">Auction</span>}</div>
      <div class="market-text"><h3>{l.title}</h3><span class="market-price">{priceLabel(l)}</span><span class="muted small market-seller-name"><AuthorName pubkey={l.pubkey} /></span></div>
    </article>
  )
}

/** The listing, in the iPhone's order: photos with previous/next, then title, price (with Auction beside it), category
 *  and location, then the seller, then the description as plain text, then Buy (Bid) on Plebeian, where checkout
 *  happens. */
export function ListingView({ listing: l, onBack }) {
  const [at, setAt] = useState(0)
  useEffect(() => { globalThis.scrollTo?.(0, 0) }, [l.id])
  const details = [l.category !== "Other" && `🏷 ${l.category}`, l.location && `📍 ${l.location}`].filter(Boolean)
  return (
    <article class="reader market-listing">
      <div class="reader-bar"><button type="button" class="small" onClick={onBack}>‹ Back</button><strong class="small">{l.isAuction ? "Auction" : "Listing"}</strong><span /></div>
      <div class="market-photo big"><img src={l.images[at]} alt="" referrerpolicy="no-referrer" /></div>
      {l.images.length > 1 && (
        <div class="market-pager">
          <button type="button" class="small" disabled={at === 0} onClick={() => setAt(at - 1)} aria-label="Previous photo">‹</button>
          <span class="muted small">{at + 1} of {l.images.length}</span>
          <button type="button" class="small" disabled={at === l.images.length - 1} onClick={() => setAt(at + 1)} aria-label="Next photo">›</button>
        </div>
      )}
      <h1 class="reader-title">{l.title}</h1>
      <div class="market-price big">{priceLabel(l)}{l.isAuction && <span class="market-badge inline">Auction</span>}</div>
      {details.length > 0 && <div class="muted small market-details">{details.map(d => <span key={d}>{d}</span>)}</div>}
      <a class="reader-byline market-seller" href={`#/profile/${l.pubkey}`}>
        <Avatar pubkey={l.pubkey} size={32} /><span><span class="muted small">Sold by</span><br /><AuthorName pubkey={l.pubkey} /></span><span class="market-chevron" aria-hidden="true">›</span>
      </a>
      {l.summary && <p class="market-description">{l.summary}</p>}
      <a class="market-buy" href={plebeianUrl(l)} target="_blank" rel="noopener noreferrer">{l.isAuction ? "Bid on Plebeian" : "Buy on Plebeian"}</a>
      <p class="muted small">Checkout happens on Plebeian Market. Nostr Vault doesn't take payments for listings.</p>
    </article>
  )
}
