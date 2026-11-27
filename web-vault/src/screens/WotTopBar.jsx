// The Web of Trust tab's top bar, as the iPhone's (TrustWebView+WOTTabBar, +Search): on the left one glass pill, the
// layer's icon + name + chevron, that opens the layers with their counts and Rebuild your web; on the right one glass
// capsule with Find someone and the Follow you back filter. Talk with you and Live arrivals are left out: the browser
// keeps no history of who you talk with, and has no relay of its own streaming new notes to fly.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { FEED_ICON } from "../components/FeedPickerMenu.jsx"
import { getProfile, putProfile } from "../net/profiles.js"
import { parseQuery, searchPeople } from "../net/search.js"
import { fromRankCopy, nameMatcher, rankPeople } from "../net/people-rank.js"
import { ownPubkeys } from "../session.js"
import { rankCopyFor } from "../net/rank-copy-store.js"
import { LAYERS } from "../net/wot.js"
import { HOP_LAYERS } from "../net/wot-hop-layers.js"

/** A circle as path data, for the icons drawn from dots. */
const dot = (x, y, r) => `M${x - r} ${y}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0`
// SF Symbol look-alikes for TrustMap.Layer.symbolName and the bar's buttons.
export const WOT_ICON = {
  everyone: [dot(12, 12, 2), dot(12, 5.5, 2), dot(12, 18.5, 2), dot(6.4, 8.8, 2), dot(17.6, 8.8, 2), dot(6.4, 15.2, 2), dot(17.6, 15.2, 2)].join(""), // circle.hexagongrid
  following: FEED_ICON.following, // person.2.fill
  close: "M12 10a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6.5 20v-.5a5.5 5.5 0 0 1 11 0v.5M5 11a2.4 2.4 0 1 0 0-4.8M19 11a2.4 2.4 0 1 1 0-4.8M2 18v-.4A4 4 0 0 1 5 13.7M22 18v-.4a4 4 0 0 0-3-3.9", // person.3.sequence.fill
  furtherOut: "M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18z", // circle.dashed (dashed when drawn)
  search: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20.5 20.5 16 16",
  followsBack: "M7 4 3 8l4 4M3 8h18M17 12l4 4-4 4M21 16H3", // arrow.left.arrow.right
  rebuild: "M21 12a9 9 0 1 1-3-6.7L21 8M21 3v5h-5", // arrow.clockwise
  clear: "M15 9l-6 6M9 9l6 6",
}
/** Hop 3, 4 and 5: the digit in a circle (SF Symbol 3.circle). */
const HopIcon = ({ digit, size }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
    <circle cx="12" cy="12" r="9" />
    <text x="12" y="16.2" text-anchor="middle" font-size="11.5" font-weight="700" fill="currentColor" stroke="none" font-family="-apple-system, system-ui, sans-serif">{digit}</text>
  </svg>
)
export const WotIcon = ({ name, size = 18 }) => /^hop\d$/.test(name) ? <HopIcon digit={name.slice(3)} size={size} /> : (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
    stroke-linejoin="round" stroke-dasharray={name === "furtherOut" ? "2.6 2.4" : undefined} aria-hidden="true"><path d={WOT_ICON[name]} /></svg>
)

/** "15K", as the iPhone's layer menu counts. */
export const compact = n => n.toLocaleString(undefined, { notation: "compact" })

/** Closes a popup on a tap outside `ref` or on Escape, while `open`. */
function useDismiss(open, setOpen, ref) {
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const esc = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", esc)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc) }
  }, [open])
}

/** The left pill (layerMenu): the picked layer; its menu lists each with "Title · 15K", then Hop 3, 4 and 5 (greyed while
 *  `locked(id)`: picking one calls `onLocked` instead), then Rebuild your web. A count that is null shows no number.
 *  `missing` is how many follows' lists didn't come back, said under Rebuild. */
export function LayerMenu({ layer, counts, onPick, onRebuild, rebuilding, missing, locked = () => true, onLocked = () => {} }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  useDismiss(open, setOpen, ref)
  const title = [...LAYERS, ...HOP_LAYERS].find(([id]) => id === layer)?.[1] ?? "Everyone"
  const n = counts?.[layer]
  return (
    <div class="wot-layer-menu" ref={ref}>
      <button type="button" class="wot-pill wot-layer-pill" aria-haspopup="menu" aria-expanded={open}
        aria-label={`Showing: ${title}${n != null ? `, ${n.toLocaleString()} people` : ""}`} onClick={() => setOpen(!open)}>
        <span class="wot-layer-icon"><WotIcon name={layer} /></span>
        <span class="wot-layer-name">{title}</span>
        <svg class="wot-chevron" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3"
          stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
      </button>
      {open && <div class="wot-menu" role="menu" aria-label="Showing">
        {LAYERS.map(([id, name]) => (
          <button key={id} type="button" role="menuitemradio" aria-checked={layer === id} class={layer === id ? "on" : ""}
            onClick={() => { setOpen(false); onPick(id) }}>
            <span class="check" aria-hidden="true">{layer === id ? "✓" : ""}</span>
            <WotIcon name={id} size={17} /><span>{name}{counts?.[id] != null ? ` · ${compact(counts[id])}` : ""}</span>
          </button>
        ))}
        {HOP_LAYERS.map(([id, name]) => {
          const off = locked(id)
          return (
            <button key={id} type="button" role="menuitemradio" aria-checked={layer === id} aria-disabled={off || undefined}
              class={[layer === id && "on", off && "locked"].filter(Boolean).join(" ")} title={off ? "A desktop Vault unlocks the far rings" : undefined}
              onClick={() => { setOpen(false); off ? onLocked(id) : onPick(id) }}>
              <span class="check" aria-hidden="true">{layer === id ? "✓" : ""}</span>
              <WotIcon name={id} size={17} /><span>{name}{!off && counts?.[id] != null ? ` · ${compact(counts[id])}` : ""}</span>
            </button>
          )
        })}
        <span class="wot-menu-sep" role="separator" />
        <button type="button" role="menuitem" disabled={rebuilding} onClick={() => { setOpen(false); onRebuild() }}>
          <span class="check" aria-hidden="true" />
          <WotIcon name="rebuild" size={17} />
          <span>{rebuilding ? "Rebuilding…" : "Rebuild your web"}
            {missing > 0 && !rebuilding && <small>{missing === 1 ? "1 follow's list didn't arrive" : `${missing.toLocaleString()} follows' lists didn't arrive`}</small>}</span>
        </button>
      </div>}
    </div>
  )
}

/** The right capsule: Find someone, then Follow you back (a filter: the people it leaves out go dim). */
export function WotToolbar({ searchOpen, onSearch, followsBack, onFollowsBack, listOpen = false, onList }) {
  return (
    <div class="wot-pill wot-tools" role="toolbar" aria-label="Web of Trust tools">
      <button type="button" class={`wot-tool${searchOpen ? " on" : ""}`} aria-pressed={searchOpen} title="Find someone" aria-label="Find someone" onClick={onSearch}>
        <WotIcon name="search" />
      </button>
      <span class="wot-tool-divider" aria-hidden="true" />
      <button type="button" class={`wot-tool${followsBack ? " on" : ""}`} aria-pressed={followsBack} title="Follow you back" aria-label="Follow you back" onClick={onFollowsBack}>
        <WotIcon name="followsBack" />
      </button>
      {onList && <>
        <span class="wot-tool-divider" aria-hidden="true" />
        <button type="button" class={`wot-tool${listOpen ? " on" : ""}`} aria-pressed={listOpen} title="See your web as a list" aria-label="See your web as a list" onClick={onList}>
          <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01" /></svg>
        </button>
      </>}
    </div>
  )
}

const RESULTS = 30
const tagOf = (web, me, pk) => (pk === me ? "You" : web?.layerOf(pk) === "follow" ? "You follow" : web?.layerOf(pk) ? "In your web" : "")
const nameOf = pk => getProfile(pk)?.name || npubEncode(pk).slice(0, 12) + "…"

/** Find someone (TrustWebView+Search): your web's names first, then relays' after a pause; a key or npub goes straight
 *  to that person. Picking one opens their card. */
export function WotSearch({ web, me, onPick, onClose, blocked = new Set(), profilesIn = 0 }) {
  const [q, setQ] = useState("")
  const [found, setFound] = useState([]) // pubkeys relays sent for this text
  const [searching, setSearching] = useState(false)
  const field = useRef(null)
  useEffect(() => { field.current?.focus() }, [])
  const text = q.trim(), parsed = parseQuery(text)
  useEffect(() => {
    setFound([])
    if (parsed.type !== "search" || text.length < 2) { setSearching(false); return }
    let live = true
    setSearching(true)
    // After 350 ms of no typing; relays get 6 s (searchRelays in +Search).
    const t = setTimeout(() => {
      searchPeople(text, { limit: 20 }) // the same people-only lookup the pickers use
        .then(evs => { if (!live) return; for (const ev of evs) putProfile(ev); setFound(evs.map(ev => ev.pubkey)) })
        .catch(() => {})
        .finally(() => { if (live) setSearching(false) })
    }, 350)
    return () => { live = false; clearTimeout(t) }
  }, [text])
  // Your web's names, then what the relays sent, in one order: the shared people ranker (net/people-rank.js), the
  // same one the Search tab uses. Blocked people are never offered, from either source.
  // Built once per web, not per render: the parent redraws on every profile batch, and two 150k Sets plus a fold of
  // every name each time was ~10x the old filter (Tron, #2689 read). "You" is every account added here (spec 1a).
  const base = useMemo(() => {
    const own = ownPubkeys()
    return { me, own, follows: new Set(web?.follows ?? []), web: new Set([...(web?.extended ?? []), ...(web?.further ?? [])]),
      everyone: [me, ...own, ...(web?.follows ?? []), ...(web?.extended ?? []), ...(web?.further ?? [])] }
  }, [web, me])
  const copy = rankCopyFor(me)
  const results = useMemo(() => {
    if (parsed.type === "profile") return [parsed.pubkey]
    const c = { ...base, blocked, profileOf: getProfile, ...fromRankCopy(copy), match: "any" }
    const match = nameMatcher(text)
    const local = !text || parsed.type !== "search" ? [] : base.everyone.filter(pk => match(getProfile(pk)) <= 3)
    return rankPeople([...local, ...found], text, c).slice(0, RESULTS)
  }, [text, found, base, blocked, copy, profilesIn])
  return (
    <div class="wot-search">
      <label class="wot-search-field">
        <WotIcon name="search" size={16} />
        <input ref={field} type="search" value={q} onInput={e => setQ(e.currentTarget.value)} placeholder="Find someone" aria-label="Find someone"
          autocapitalize="off" autocorrect="off" spellcheck={false} onKeyDown={e => { if (e.key === "Escape") onClose() }} />
        {q && <button type="button" class="wot-search-clear" aria-label="Clear" onClick={() => { setQ(""); field.current?.focus() }}><WotIcon name="clear" size={14} /></button>}
      </label>
      {text && <div class="wot-results" role="listbox" aria-label="People">
        {results.map(pk => {
          const p = getProfile(pk), tag = tagOf(web, me, pk)
          return (
            <button key={pk} type="button" role="option" class="wot-result" onClick={() => onPick(pk)}>
              <Avatar pubkey={pk} size={32} />
              <span class="wot-result-names"><b>{nameOf(pk)}</b>{p?.nip05 && <small>{p.nip05.replace(/^_@/, "")}</small>}</span>
              {tag && <span class="wot-result-tag">{tag}</span>}
            </button>
          )
        })}
        {!results.length && <p class="wot-results-note">{searching ? "Searching relays…" : `No one called “${text}” yet.`}</p>}
        {results.length > 0 && searching && <p class="wot-results-note">Searching relays…</p>}
      </div>}
    </div>
  )
}
