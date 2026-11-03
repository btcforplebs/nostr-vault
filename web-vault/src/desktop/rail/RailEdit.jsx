// Editing the left rail (Logen, 2026-11-03): a panel beside the rail with its favourites in order, each with up/down,
// a drag grip and take off (Feed stays), and below them what can be pinned: a section taken off, a feed from the Feed's
// picker, a hashtag, a person (an npub, or a name among the people you follow), a relay's feed, or one of your people
// lists. Every change is kept at once (space/layout-store.js) and synced with Your space's layout.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { decode } from "nostr-tools/nip19"
import { getProfile } from "../../net/profiles.js"
import { normalizeTag } from "../../net/feeds.js"
import { myLists } from "../../net/list-feed.js"
import { setRail } from "../space/space-layout.js"
import { defaultRail, favKey, HOME, missingSections, moveFav, moveFavBefore, normalizeRelay, pin, sameRail, shownFavs, unpin } from "./rail-favs.js"
import { FEEDS, FEED_IDS, FavIcon, SECTION, favTitle } from "./RailFavs.jsx"
import { useDragPanels } from "../space/SpaceEdit.jsx"
import { Icon } from "../icons.jsx"

const UP = "M6 15l6-6 6 6", DOWN = "M6 9l6 6 6-6", OFF = "M6 6l12 12M18 6L6 18", GRIP = "M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01"
const HEX = /^[0-9a-f]{64}$/

/** What the person box holds -> a pubkey: an npub or nprofile, or 64 hex; null otherwise. */
export function personKey(text) {
  const s = String(text ?? "").trim().replace(/^nostr:/, "")
  if (HEX.test(s.toLowerCase())) return s.toLowerCase()
  try {
    const { type, data } = decode(s)
    if (type === "npub") return data
    if (type === "nprofile") return data.pubkey
  } catch {}
  return null
}

/** Up to `n` of `people` whose cached name has `text` in it. */
export function nameMatches(text, people, n = 5) {
  const q = String(text ?? "").trim().toLowerCase()
  if (q.length < 2) return []
  const out = []
  for (const pk of people) {
    const p = getProfile(pk)
    const name = `${p?.display_name ?? ""} ${p?.name ?? ""}`.toLowerCase()
    if (name.includes(q)) out.push(pk)
    if (out.length >= n) break
  }
  return out
}

export function RailEdit({ ctx, layout, change, onClose }) {
  const rail = layout.rail
  const shown = shownFavs(rail, FEED_IDS)
  const edit = fn => change(l => setRail(l, fn(l.rail)))
  const box = useRef()
  useEffect(() => {
    const away = e => { if (!box.current?.contains(e.target) && !e.target.closest?.(".side-edit-btn")) onClose() }
    const esc = e => { if (e.key === "Escape") { e.preventDefault(); onClose() } }
    addEventListener("pointerdown", away); addEventListener("keydown", esc, true)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc, true) }
  }, [])
  const keys = shown.map(favKey)
  const drag = useDragPanels(keys, (key, before) => edit(r => moveFavBefore(r, key, before)))
  return (
    <div class="rail-edit" role="dialog" aria-label="Edit the rail" ref={box}>
      <header class="rail-edit-head">
        <h3>Your rail</h3>
        <button type="button" class="sp-done" onClick={onClose}>Done</button>
      </header>
      <p class="rail-edit-hint">Drag or use the arrows to reorder. Pin a feed, a person, a hashtag, a list or a relay below.</p>
      <ul class="rail-edit-list">
        {shown.map((f, i) => {
          const k = favKey(f), name = favTitle(f, f.type === "person" ? getProfile(f.pubkey) : null)
          return (
            <li key={k} class={drag.over === k ? `rail-edit-row drop-${drag.side}` : "rail-edit-row"} {...drag.slot(k)}>
              <span class="rail-edit-icon"><FavIcon fav={f} size={20} /></span>
              <span class="rail-edit-name">{name}<span class="rail-edit-kind">{f.type === "section" ? "" : f.type === "feed" ? "Feed" : f.type === "person" ? "Person" : f.type === "hashtag" ? "Hashtag" : f.type === "list" ? "List" : "Relay"}</span></span>
              <button type="button" class="sp-btn" disabled={i === 0} aria-label={`Move ${name} up`} title="Move up" onClick={() => edit(r => moveFav(r, k, -1, FEED_IDS))}><Icon d={UP} size={16} /></button>
              <button type="button" class="sp-btn" disabled={i === shown.length - 1} aria-label={`Move ${name} down`} title="Move down" onClick={() => edit(r => moveFav(r, k, 1, FEED_IDS))}><Icon d={DOWN} size={16} /></button>
              <button type="button" class="sp-btn sp-off" disabled={f.type === "section" && f.id === HOME} aria-label={`Take ${name} off the rail`}
                title={f.type === "section" && f.id === HOME ? "Feed stays on the rail" : "Take off the rail"} onClick={() => edit(r => unpin(r, k))}><Icon d={OFF} size={16} /></button>
              <span class="sp-grip" aria-hidden="true"><Icon d={GRIP} size={18} /></span>
            </li>
          )
        })}
      </ul>
      <Pinner ctx={ctx} rail={rail} onPin={f => edit(r => pin(r, f))} />
      {!sameRail(rail, defaultRail()) && <button type="button" class="sp-link sp-reset" onClick={() => edit(() => defaultRail())}>Reset the rail</button>}
    </div>
  )
}

/** Everything that can be pinned. Each kind adds at the end of the rail. */
function Pinner({ ctx, rail, onPin }) {
  const has = k => rail.some(f => favKey(f) === k)
  const sections = missingSections(rail)
  const feeds = FEEDS.filter(f => f.id !== HOME && !has(`feed:${f.id}`))
  const [feed, setFeed] = useState("")
  const [tag, setTag] = useState("")
  const [who, setWho] = useState("")
  const [relay, setRelay] = useState("")
  const [lists, setLists] = useState(null)
  const [err, setErr] = useState("")
  useEffect(() => { let live = true; myLists(ctx).then(l => live && setLists(l)).catch(() => live && setLists([])); return () => { live = false } }, [])
  const matches = useMemo(() => (personKey(who) ? [] : nameMatches(who, ctx.account.follows)), [who])
  const add = (f, clear) => { setErr(""); onPin(f); clear?.("") }
  return (
    <div class="rail-pin">
      <h4>Pin to the rail</h4>
      {sections.length > 0 && <div class="rail-pin-row">
        {sections.map(id => <button key={id} type="button" class="sp-add-row" onClick={() => add({ type: "section", id })}><Icon d="M12 5v14M5 12h14" size={14} />{SECTION[id][0]}</button>)}
      </div>}
      <form class="rail-pin-form" onSubmit={e => { e.preventDefault(); if (feed) add({ type: "feed", mode: feed }, setFeed) }}>
        <label for="rail-pin-feed">Feed</label>
        <select id="rail-pin-feed" value={feed} onChange={e => setFeed(e.currentTarget.value)}>
          <option value="">Pick a feed…</option>
          {feeds.map(f => <option key={f.id} value={f.id}>{f.label}</option>)}
        </select>
        <button type="submit" class="small" disabled={!feed}>Pin</button>
      </form>
      <form class="rail-pin-form" onSubmit={e => { e.preventDefault(); const t = normalizeTag(tag); if (!t) return setErr("A hashtag is one word, like #bitcoin."); add({ type: "hashtag", tag: t }, setTag) }}>
        <label for="rail-pin-tag">Hashtag</label>
        <input id="rail-pin-tag" value={tag} onInput={e => setTag(e.currentTarget.value)} placeholder="#bitcoin" autocapitalize="off" spellcheck={false} />
        <button type="submit" class="small" disabled={!tag.trim()}>Pin</button>
      </form>
      <form class="rail-pin-form" onSubmit={e => { e.preventDefault(); const pk = personKey(who) ?? (matches.length === 1 ? matches[0] : null); if (!pk) return setErr("Paste an npub, or type a name and pick them."); add({ type: "person", pubkey: pk }, setWho) }}>
        <label for="rail-pin-who">Person</label>
        <input id="rail-pin-who" value={who} onInput={e => setWho(e.currentTarget.value)} placeholder="Name or npub1…" autocapitalize="off" spellcheck={false} />
        <button type="submit" class="small" disabled={!who.trim()}>Pin</button>
      </form>
      {matches.length > 0 && <div class="rail-pin-matches">
        {matches.map(pk => <button key={pk} type="button" class="sp-add-row" onClick={() => add({ type: "person", pubkey: pk }, setWho)}>
          <FavIcon fav={{ type: "person", pubkey: pk }} size={18} />{favTitle({ type: "person", pubkey: pk }, getProfile(pk))}</button>)}
      </div>}
      <form class="rail-pin-form" onSubmit={e => { e.preventDefault(); const url = normalizeRelay(relay); if (!url) return setErr("A relay address starts with wss://"); add({ type: "relay", url }, setRelay) }}>
        <label for="rail-pin-relay">Relay</label>
        <input id="rail-pin-relay" value={relay} onInput={e => setRelay(e.currentTarget.value)} placeholder="wss://relay.example" autocapitalize="off" spellcheck={false} />
        <button type="submit" class="small" disabled={!relay.trim()}>Pin</button>
      </form>
      <div class="rail-pin-lists">
        <span class="rail-pin-label">Your lists</span>
        {lists === null ? <span class="muted small">Reading your lists…</span>
          : !lists.length ? <span class="muted small">No people lists on your account yet.</span>
          : lists.map(l => {
            const k = `list:${l.pubkey}:${l.d}`
            return <button key={k} type="button" class="sp-add-row" disabled={has(k)} onClick={() => add({ type: "list", pubkey: l.pubkey, d: l.d, name: l.name })}>
              <FavIcon fav={{ type: "list" }} size={16} />{l.name}<span class="muted small">{l.people}</span></button>
          })}
      </div>
      {err && <p class="rail-pin-error" role="alert">{err}</p>}
    </div>
  )
}
