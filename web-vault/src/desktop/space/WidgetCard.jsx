// One of our Your space panels drawn as a card (plan NV_WEB_ONE_PLAN.md step 4), while napplets are on (flag.js): the
// shell draws the header (icon, name, count, collapse or the edit tools), our widget napplet draws the body in its own
// walled-off frame (first-party.js widgetFor), and the shell answers what it asks (widget-answers.js) through
// shell-answered intents. Live now and On this day are read on ask; the other four by the panels' own hooks
// (widget-sources.jsx), which also set the header's badge, and their clicks open only routes the shell kept
// (napplet:space/open). The footer link is the shell's. Same cost rules as an app card (AppCard.jsx): a frame slot
// from frames.js, none while the columns are edited, and a collapsed card's frame closes after a minute. Napplets off: the panel itself (panels.js).
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { usePaneNapplet } from "../../napplet/usePaneNapplet.js"
import { widgetFor } from "../../napplet/first-party.js"
import { getBlocks } from "../../net/blocks.js"
import { fetchProfiles, getProfile } from "../../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../../net/pool.js"
import { LiveSheet } from "../../readers/LiveEmbed.jsx"
import { Icon } from "../icons.jsx"
import { liveNow } from "./live-now.js"
import { readOnThisDay } from "./on-this-day.js"
import { claimFrame, whenFree } from "./frames.js"
import { CARD_ICON } from "./card-icons.js"
import { surfaceAnswer, fitHeight, countOf, liveNowData, thisDayData, noteRoute, openRoute, sameBadge } from "./widget-answers.js"
import { SOURCES } from "./widget-sources.jsx"
import { CLOSE_AFTER_MS } from "./AppCard.jsx"
import "../../napplet/napplet.css"

/** Whether panel `id` draws as a widget card here. */
export const isWidget = id => !!widgetFor(id)

/** The intent each source-drawn card (widget-sources.jsx) asks for its data: napplet:space/<this>. */
export const SOURCE_ASK = { "live-vault": "vault", messages: "messages", "my-devices": "devices", "wot-mini": "wot" }
/** The shell's own footer link under each card that had one as a panel. */
export const CARD_FOOT = {
  "live-vault": ["#/vault/activity", "Open the Vault list ›"],
  messages: ["#/messages", "Open Messages ›"],
  "my-devices": ["#/relay", "Who Can Reach You ›"],
  "wot-mini": ["#/wot", "Open the globe ›"],
}

/** What a source last put (data, routes) and who to tell when it changes: the frame, to ask again. */
function makePipe() {
  const listeners = new Set()
  let key = null
  return {
    data: null, routes: new Map(),
    put(data, routes) {
      this.routes = routes
      const k = JSON.stringify(data)
      if (k === key) return
      key = k; this.data = data
      for (const l of listeners) l()
    },
    on(l) { listeners.add(l); return () => listeners.delete(l) },
  }
}

/**
 * The shell's answers for card `id`. `state()` reads the card's size and side now; `ui` is what the shell does for it
 * (open a stream's player, set the header's count, the Fit height); `pipe` holds a source-drawn card's data.
 */
function answersFor(id, ctx, state, ui, pipe) {
  const me = () => ctx.session.pubkey
  const base = [
    { archetype: "shell", actions: ["surface"], deliver: () => ({ data: surfaceAnswer(state().size, state().side) }) },
    { archetype: "card", actions: ["height"], deliver: p => { ui.height(fitHeight(p?.height)); return {} } },
    { archetype: "card", actions: ["count"], deliver: p => { const c = countOf(p?.count); ui.badge(c ? { text: String(c), label: id === "live-now" ? `${c} live` : String(c) } : null); return {} } },
  ]
  if (SOURCE_ASK[id]) {
    return [...base,
      { archetype: "space", actions: [SOURCE_ASK[id]], deliver: () => ({ data: pipe.data }) },
      { archetype: "space", actions: ["open"], deliver: p => {
        const to = openRoute(pipe.routes, p?.id)
        if (!to) return { ok: false, error: "not a row this card shows" }
        location.hash = to
        return {}
      } },
    ]
  }
  if (id === "live-now") {
    const streams = new Map() // address -> stream, only the ones this card was handed
    return [...base,
      { archetype: "space", actions: ["livenow"], deliver: async () => {
        await accountLoaded(ctx)
        const follows = ctx.account.follows.filter(pk => pk !== me())
        const list = follows.length ? await liveNow({ me: me(), follows, readRelays: ctx.account.relays.read, blocked: getBlocks().blocked }) : []
        if (list.length) await fetchProfiles(ctx.vault, list.map(s => s.host), uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { save: false }).catch(() => {})
        const data = liveNowData(list, getProfile, follows.length > 0)
        streams.clear()
        for (const s of list) if (data.rows.some(r => r.address === s.address)) streams.set(s.address, s)
        return { data }
      } },
      { archetype: "live", actions: ["open"], deliver: p => {
        const s = streams.get(p?.address)
        if (!s) return { ok: false, error: "not a stream this card shows" }
        ui.play(s)
        return {}
      } },
    ]
  }
  if (id === "on-this-day") {
    return [...base,
      { archetype: "space", actions: ["thisday"], deliver: async () => ({ data: thisDayData(await readOnThisDay(ctx.vault, me())) }) },
      { archetype: "note", actions: ["show"], deliver: p => {
        const to = noteRoute(p?.id)
        if (!to) return { ok: false, error: "not a note id" }
        location.hash = to
        return {}
      } },
    ]
  }
  return base
}

/** Waits (at most ACCOUNT_WAIT_MS) for the account's follows, so a card opened at start doesn't say "follow people". */
const ACCOUNT_WAIT_MS = 15_000
async function accountLoaded(ctx) {
  for (const t0 = Date.now(); !ctx.account.loaded && Date.now() - t0 < ACCOUNT_WAIT_MS;) await new Promise(r => setTimeout(r, 250))
}

/** Tells the card to ask again (inc nv.card.again) when what it shows may have changed, as the panels re-read. */
export const AGAIN_TOPIC = "nv.card.again"

const asHandlers = (dTag, list) => list.map(h => ({ id: `shell:${dTag}`, title: "Nostr Vault", conventions: [], ...h }))

/** The frame itself: mounted only while the card runs (WidgetCard holds the slot). */
function WidgetFrame({ ctx, id, state, ui, pipe }) {
  const host = useRef(null)
  const n = widgetFor(id)
  const handlers = useMemo(() => asHandlers(n.dTag, answersFor(id, ctx, state, ui, pipe)), [id])
  const { live, note, ready } = usePaneNapplet(ctx, host, { dTag: n.dTag, handlers })
  const blocked = getBlocks().blocked
  const again = [ctx.account.loaded, ctx.account.follows.length, ctx.account.follows[0], blocked.size].join(":")
  const first = useRef(true)
  useEffect(() => {
    if (!ready) return
    if (first.current) { first.current = false; return }
    live.current?.bus.emit(live.current.me, AGAIN_TOPIC, {})
  }, [ready, again])
  // A source-drawn card asks again when its source's data changes.
  useEffect(() => (ready ? pipe.on(() => live.current?.bus.emit(live.current.me, AGAIN_TOPIC, {})) : undefined), [ready])
  return (
    <>
      {note && <p class="sp-empty">{note}</p>}
      <div class="napplet-host sp-app-host on" ref={host} />
    </>
  )
}

/** Same props as a panel (panels.js) plus the card's size and side; `full`: the rail opened it alone, full height. */
export function WidgetCard({ ctx, id, name, open, editing, tools, size = null, side, full = false }) {
  const [wanted, setWanted] = useState(open && !editing)
  const [slot, setSlot] = useState(false)
  const [busy, setBusy] = useState(false) // every frame slot is taken
  const [fit, setFit] = useState(null)
  const [badge, setBadgeNow] = useState(null)
  const setBadge = useMemo(() => next => setBadgeNow(was => (sameBadge(was, next) ? was : next)), [])
  const pipe = useMemo(makePipe, [])
  const Source = SOURCES[id]
  const [playing, setPlaying] = useState(null)
  const now = useRef({ size, side })
  now.current = { size: full ? "L" : size, side }
  const ui = useMemo(() => ({ height: setFit, badge: setBadge, play: setPlaying }), [])
  const put = useMemo(() => ({ data, routes, badge }) => { setBadge(badge); pipe.put(data, routes) }, [])
  useEffect(() => {
    if (open && !editing) { setWanted(true); return }
    if (editing) { setWanted(false); return }
    const t = setTimeout(() => setWanted(false), CLOSE_AFTER_MS)
    return () => clearTimeout(t)
  }, [open, editing])
  const [tries, setTries] = useState(0)
  useEffect(() => {
    if (!wanted) { setSlot(false); return }
    const release = claimFrame(`ours:${id}`)
    if (!release) { setBusy(true); return whenFree(() => setTries(t => t + 1)) }
    setBusy(false); setSlot(true)
    return () => { setSlot(false); release() }
  }, [wanted, tries])
  const shown = open && !editing
  const sized = full || size
  return (
    <section class={shown ? `sp-panel sp-widget ${id}` : `sp-panel sp-widget ${id} closed`} aria-label={name}>
      <header class="sp-head">
        <span class="sp-icon"><Icon d={CARD_ICON[id]} size={15} /></span>
        <h3>{name}</h3>
        {id === "live-vault" && <span class="sp-live" title="New lines come in while this page is open"><span class="sp-pulse" />Live</span>}
        {badge && <span class={badge.cls ?? (id === "live-now" ? "ln-count" : "sp-count")} role="img" aria-label={badge.label}>{badge.text}</span>}
        {tools}
      </header>
      {wanted && (
        <div class="sp-app-body sp-widget-body" style={!shown ? { display: "none" } : !sized && fit ? { height: `${fit}px`, flex: "none" } : undefined}>
          {busy ? <p class="sp-empty">Too many cards are open. Collapse one and this opens.</p>
            : slot ? <WidgetFrame ctx={ctx} id={id} state={() => now.current} ui={ui} pipe={pipe} /> : null}
        </div>
      )}
      {shown && CARD_FOOT[id] && <a class="sp-foot" href={CARD_FOOT[id][0]}>{CARD_FOOT[id][1]}</a>}
      {Source && <Source ctx={ctx} open={shown} put={put} />}
      {playing && <LiveSheet ctx={ctx} stream={playing} onClose={() => setPlaying(null)} />}
    </section>
  )
}
