// The Feed, Thread and someone's Profile as napplets (plan P4), when the napplet switch is on (flag.js): the Reader
// napplet fills the screen, and the Compose napplet opens in a sheet when the Reader asks (reader-intents.js). Both
// are ours (first-party grant, policy.js), answered by the same runtime as the Apps pane. Switch off: the old screens.
// `open`: { archetype, action, payload } to show first (a #/thread/<id> or #/profile/<pubkey> address), else the feed.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps } from "./shell-deps.js"
import { firstParty, READER_DTAG, COMPOSE_DTAG } from "./first-party.js"
import { readerIntents } from "./reader-intents.js"
import "./napplet.css"

const READY_WAIT_MS = 5000
const whenReady = async m => { await Promise.race([m.napplet.ready, new Promise(r => setTimeout(r, READY_WAIT_MS))]); return m.napplet }

export function ReaderPane({ ctx, open = null }) {
  const host = useRef(null), composeHost = useRef(null)
  const [composing, setComposing] = useState(false)
  const [note, setNote] = useState("")
  const grants = useMemo(() => grantStore(localStorage, ctx.session.pubkey), [ctx.session.pubkey])
  const live = useRef(null) // { bus, me, reader }
  const openRef = useRef(open)
  openRef.current = open

  useEffect(() => {
    const bus = createBus()
    let reader = null, compose = null, composeWaiters = [], gone = false
    const mount = async (dTag, container, onGone) => {
      const n = firstParty(dTag)
      const r = await openNapplet({
        html: n.html, name: n.dTag, title: n.title, firstParty: true, domains: n.domains, container, grants,
        consent: async () => null, // first-party: never asked
        makeDeps: saveGrant => shellDeps(ctx, { ask: async () => false, saveGrant, bus }),
        onRevoke: why => { onGone(); if (!gone && why !== "closed by shell") setNote(`${n.title} closed: ${why}.`) },
      })
      return r.mounted
    }
    // Compose: mounted in the sheet on the first ask, kept while the sheet is open.
    const openCompose = () => new Promise((resolve, reject) => {
      if (compose) return resolve(whenReady(compose))
      composeWaiters.push({ resolve, reject })
      setComposing(true)
    })
    live.current = {
      bus,
      mountCompose: async container => {
        try {
          compose = await mount(COMPOSE_DTAG, container, () => { compose = null })
          const napplet = await whenReady(compose)
          composeWaiters.splice(0).forEach(w => w.resolve(napplet))
        } catch (e) { composeWaiters.splice(0).forEach(w => w.reject(e)) }
      },
      closeCompose: () => { compose?.close(); compose = null; setComposing(false) },
    }
    const wire = readerIntents({
      bus, openCompose,
      onComposeDone: () => live.current?.closeCompose(),
      openUrl: url => window.open(url, "_blank", "noopener,noreferrer"),
    })
    live.current.me = wire.me
    ;(async () => {
      try {
        reader = await mount(READER_DTAG, host.current, () => { reader = null })
        if (gone) return reader.close()
        const readerNapplet = await whenReady(reader)
        const offs = ["note", "profile", "feed"].map(archetype => bus.register({ id: "nv-reader", title: "Reader", archetype, actions: ["open"], conventions: [], open: async () => readerNapplet }))
        live.current.reader = { offs }
        if (openRef.current) bus.invoke(wire.me, openRef.current)
      } catch (e) { if (!gone) setNote(`The Reader couldn't open: ${e?.message ?? e}`) }
    })()
    return () => { gone = true; wire.close(); live.current?.reader?.offs.forEach(f => f()); reader?.close(); compose?.close(); live.current = null }
  }, [ctx, grants])

  // A new address (another thread or profile) while the Reader is up: hand it over instead of mounting again.
  const opened = useRef(JSON.stringify(open))
  useEffect(() => {
    const key = JSON.stringify(open)
    if (key === opened.current) return
    opened.current = key
    const l = live.current
    if (l?.reader) l.bus.invoke(l.me, open ?? { archetype: "feed", action: "open", payload: {} })
  }, [open])

  return (
    <main class="screen reader-pane">
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host reader-host" ref={host} />
      {composing && (
        <Dialog label="Compose" onClose={() => live.current?.closeCompose()}>
          <ComposeMount onMount={el => live.current?.mountCompose(el)} />
        </Dialog>
      )}
    </main>
  )
}

function ComposeMount({ onMount }) {
  const ref = useRef(null)
  useEffect(() => { onMount(ref.current) }, [])
  return <div class="napplet-host compose-napplet-host" ref={ref} />
}
