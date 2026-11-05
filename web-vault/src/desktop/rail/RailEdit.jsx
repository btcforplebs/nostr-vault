// Editing the left rail (Logen, 2026-11-03): a panel beside the rail with its pins in order, each with up/down and a
// drag grip, favourites with take off (sections move but never go, docs/SPACE_LAYOUT.md), and below them what can be
// pinned: a hashtag, a person (an npub, or a name among the people you follow), a relay's feed, or one of your people
// lists. Every change is kept at once (space/layout-store.js) and synced with Your space's layout.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { decode } from "nostr-tools/nip19"
import { getProfile } from "../../net/profiles.js"
import { myLists } from "../../net/list-feed.js"
import { setPins } from "../space/space-layout.js"
import { defaultPins, favourite, movePin, movePinBefore, pin, pinKey, samePins, shownPins, unpin, MAX_FAVOURITES, isFavourite, isPinned, feedPinToWeb, webHasFeedPin } from "./rail-favs.js"
import { KIND_NAME, PinIcon, pinTitle, FEED_NAME } from "./RailFavs.jsx"
import { FEED_ICON, LIST_ICON } from "../../components/FeedPickerMenu.jsx"
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
  const pins = layout.pins
  const shown = shownPins(pins)
  const edit = fn => change(l => setPins(l, fn(l.pins)))
  const box = useRef()
  useEffect(() => {
    const away = e => { if (!box.current?.contains(e.target) && !e.target.closest?.(".side-edit-btn")) onClose() }
    const esc = e => { if (e.key === "Escape") { e.preventDefault(); onClose() } }
    addEventListener("pointerdown", away); addEventListener("keydown", esc, true)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc, true) }
  }, [])
  const keys = shown.map(pinKey)
  const drag = useDragPanels(keys, (key, before) => edit(r => movePinBefore(r, key, before)))
  return (
    <div class="rail-edit" role="dialog" aria-label="Edit the rail" ref={box}>
      <header class="rail-edit-head">
        <h3>Your rail</h3>
        <button type="button" class="sp-done" onClick={onClose}>Done</button>
      </header>
      <p class="rail-edit-hint">Drag or use the arrows to reorder. Pin a feed, a person, a hashtag, a list or a relay below.</p>
      <ul class="rail-edit-list">
        {shown.map((p, i) => {
          const k = pinKey(p), name = pinTitle(p, p.type === "person" ? getProfile(p.p) : null)
          return (
            <li key={k} class={drag.over === k ? `rail-edit-row drop-${drag.side}` : "rail-edit-row"} {...drag.slot(k)}>
              <span class="rail-edit-icon"><PinIcon pin={p} size={18} /></span>
              <span class="rail-edit-name">{name}<span class="rail-edit-kind">{KIND_NAME[p.type] ?? ""}</span></span>
              <button type="button" class="sp-btn" disabled={i === 0} aria-label={`Move ${name} up`} title="Move up" onClick={() => edit(r => movePin(r, k, -1))}><Icon d={UP} size={16} /></button>
              <button type="button" class="sp-btn" disabled={i === shown.length - 1} aria-label={`Move ${name} down`} title="Move down" onClick={() => edit(r => movePin(r, k, 1))}><Icon d={DOWN} size={16} /></button>
              {isFavourite(p)
                ? <button type="button" class="sp-btn sp-off" aria-label={`Take ${name} off the rail`} title="Take off the rail" onClick={() => edit(r => unpin(r, k))}><Icon d={OFF} size={16} /></button>
                : <span class="rail-edit-stay" title="Sections can move but stay on the rail" aria-hidden="true" />}
              <span class="sp-grip" aria-hidden="true"><Icon d={GRIP} size={18} /></span>
            </li>
          )
        })}
      </ul>
      <FeedPins pins={pins} onToggle={f => edit(r => (isPinned(r, f) ? unpin(r, pinKey(f)) : pin(r, f)))} />
      <Pinner ctx={ctx} pins={pins} onPin={f => edit(r => pin(r, f))} />
      {!samePins(pins, defaultPins()) && <button type="button" class="sp-link sp-reset" onClick={() => edit(() => defaultPins())}>Reset the rail</button>}
    </div>
  )
}

/** Everything that can be pinned. Each one goes at the end of the rail. */
function Pinner({ ctx, pins, onPin }) {
  const has = f => !!f && pins.some(p => pinKey(p) === pinKey(f))
  const full = pins.filter(isFavourite).length >= MAX_FAVOURITES
  const [tag, setTag] = useState("")
  const [who, setWho] = useState("")
  const [relay, setRelay] = useState("")
  const [lists, setLists] = useState(null)
  const [err, setErr] = useState("")
  useEffect(() => { let live = true; myLists(ctx).then(l => live && setLists(l)).catch(() => live && setLists([])); return () => { live = false } }, [])
  const matches = useMemo(() => (personKey(who) ? [] : nameMatches(who, ctx.account.follows)), [who])
  const add = (f, clear, why) => {
    if (!f) return setErr(why)
    if (full) return setErr(`The rail holds ${MAX_FAVOURITES} favourites. Take one off first.`)
    setErr(""); onPin(f); clear?.("")
  }
  const person = pk => favourite("person", pk, getProfile(pk)?.display_name || getProfile(pk)?.name)
  return (
    <div class="rail-pin">
      <h4>Pin to the rail</h4>
      <form class="rail-pin-form" onSubmit={e => { e.preventDefault(); add(favourite("hashtag", tag), setTag, "A hashtag is one word, like #bitcoin.") }}>
        <label for="rail-pin-tag">Hashtag</label>
        <input id="rail-pin-tag" value={tag} onInput={e => setTag(e.currentTarget.value)} placeholder="#bitcoin" autocapitalize="off" spellcheck={false} />
        <button type="submit" class="small" disabled={!tag.trim()}>Pin</button>
      </form>
      <form class="rail-pin-form" onSubmit={e => { e.preventDefault(); const pk = personKey(who) ?? (matches.length === 1 ? matches[0] : null); add(pk && person(pk), setWho, "Paste an npub, or type a name and pick them.") }}>
        <label for="rail-pin-who">Person</label>
        <input id="rail-pin-who" value={who} onInput={e => setWho(e.currentTarget.value)} placeholder="Name or npub1…" autocapitalize="off" spellcheck={false} />
        <button type="submit" class="small" disabled={!who.trim()}>Pin</button>
      </form>
      {matches.length > 0 && <div class="rail-pin-matches">
        {matches.map(pk => <button key={pk} type="button" class="sp-add-row" onClick={() => add(person(pk), setWho)}>
          <PinIcon pin={{ type: "person", p: pk }} size={12} />{pinTitle({ type: "person", p: pk }, getProfile(pk))}</button>)}
      </div>}
      <form class="rail-pin-form" onSubmit={e => { e.preventDefault(); add(favourite("relay", relay), setRelay, "A relay address starts with wss://") }}>
        <label for="rail-pin-relay">Relay</label>
        <input id="rail-pin-relay" value={relay} onInput={e => setRelay(e.currentTarget.value)} placeholder="wss://relay.example" autocapitalize="off" spellcheck={false} />
        <button type="submit" class="small" disabled={!relay.trim()}>Pin</button>
      </form>
      <div class="rail-pin-lists">
        <span class="rail-pin-label">Your lists</span>
        {lists === null ? <span class="muted small">Reading your lists…</span>
          : !lists.length ? <span class="muted small">No people lists on your account yet.</span>
          : lists.map(l => {
            const f = favourite("list", l.a, l.name)
            return <button key={l.a} type="button" class="sp-add-row" disabled={has(f)} onClick={() => add(f)}>
              <PinIcon pin={{ type: "list" }} size={16} />{l.name}<span class="muted small">{l.people}</span></button>
          })}
      </div>
      {err && <p class="rail-pin-error" role="alert">{err}</p>}
    </div>
  )
}

/** Feed types the left rail can carry (Logen, 2026-11-05: on the left rail, picked here in its Edit, not in Your space; the iPad's RailEditSheet): a click pins one there as
 *  { type: "feed", id }, another takes it off. Following is the Feed section itself, so it isn't offered. */
function FeedPins({ pins, onToggle }) {
  return (
    <section class="sp-feed-pins" aria-label="Feeds on your rail">
      <p class="sp-feed-pins-head">Feeds on your rail</p>
      <div class="sp-feed-pins-grid">
        {Object.entries(FEED_NAME).filter(([id]) => webHasFeedPin({ type: "feed", id })).map(([id, name]) => {
          const f = favourite("feed", id)
          const on = isPinned(pins, f)
          return (
            <button key={id} type="button" class={on ? "sp-feed-pin on" : "sp-feed-pin"} aria-pressed={on}
              aria-label={on ? `${name} on your rail. Take off` : `Add ${name} to your rail`} onClick={() => onToggle(f)}>
              <Icon d={on ? "M5 12l5 5 9-10" : FEED_ICON[feedPinToWeb(id)] ?? LIST_ICON} size={14} />{name}
            </button>
          )
        })}
      </div>
    </section>
  )
}
