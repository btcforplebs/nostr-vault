// One of our Your space panels drawn as a card (plan NV_WEB_ONE_PLAN.md step 4), while napplets are on (flag.js): the
// shell draws the header (icon, name, count, collapse or the edit tools), our widget napplet draws the body in its own
// walled-off frame (first-party.js widgetFor), and the shell answers what it asks (widget-answers.js) through
// shell-answered intents. Same cost rules as an app card (AppCard.jsx): a frame slot from frames.js, none while the
// columns are edited, and a collapsed card's frame closes after a minute. Napplets off: the panel itself (panels.js).
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
import { surfaceAnswer, fitHeight, countOf, liveNowData, thisDayData, noteRoute } from "./widget-answers.js"
import { CLOSE_AFTER_MS } from "./AppCard.jsx"
import "../../napplet/napplet.css"

/** Whether panel `id` draws as a widget card here. */
export const isWidget = id => !!widgetFor(id)

/**
 * The shell's answers for card `id`. `state()` reads the card's size and side now; `ui` is what the shell does for it
 * (open a stream's player, set the header's count, the Fit height).
 */
function answersFor(id, ctx, state, ui) {
  const me = () => ctx.session.pubkey
  const base = [
    { archetype: "shell", actions: ["surface"], deliver: () => ({ data: surfaceAnswer(state().size, state().side) }) },
    { archetype: "card", actions: ["height"], deliver: p => { ui.height(fitHeight(p?.height)); return {} } },
    { archetype: "card", actions: ["count"], deliver: p => { ui.count(countOf(p?.count)); return {} } },
  ]
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
function WidgetFrame({ ctx, id, state, ui }) {
  const host = useRef(null)
  const n = widgetFor(id)
  const handlers = useMemo(() => asHandlers(n.dTag, answersFor(id, ctx, state, ui)), [id])
  const { live, note, ready } = usePaneNapplet(ctx, host, { dTag: n.dTag, handlers })
  const blocked = getBlocks().blocked
  const again = [ctx.account.loaded, ctx.account.follows.length, ctx.account.follows[0], blocked.size].join(":")
  const first = useRef(true)
  useEffect(() => {
    if (!ready) return
    if (first.current) { first.current = false; return }
    live.current?.bus.emit(live.current.me, AGAIN_TOPIC, {})
  }, [ready, again])
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
  const [count, setCount] = useState(0)
  const [playing, setPlaying] = useState(null)
  const now = useRef({ size, side })
  now.current = { size: full ? "L" : size, side }
  const ui = useMemo(() => ({ height: setFit, count: setCount, play: setPlaying }), [])
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
        {count > 0 && <span class="ln-count" role="img" aria-label={id === "live-now" ? `${count} live` : String(count)}>{count}</span>}
        {tools}
      </header>
      {wanted && (
        <div class="sp-app-body sp-widget-body" style={!shown ? { display: "none" } : !sized && fit ? { height: `${fit}px`, flex: "none" } : undefined}>
          {busy ? <p class="sp-empty">Too many cards are open. Collapse one and this opens.</p>
            : slot ? <WidgetFrame ctx={ctx} id={id} state={() => now.current} ui={ui} /> : null}
        </div>
      )}
      {playing && <LiveSheet ctx={ctx} stream={playing} onClose={() => setPlaying(null)} />}
    </section>
  )
}
