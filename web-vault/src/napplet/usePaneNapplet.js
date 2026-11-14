// One of our own napplets filling a screen of the app (plan P8): the mount the Media, WoT and Messages panes shared.
// Mounted once per account; first-party grant (policy.js), never asked. The pane's bus gets:
//   handlers: shell-answered intents (bus.js `deliver`), live from the start;
//   actions:  { archetype: [action] } the napplet itself takes, registered once it can take a delivery.
// -> { live: ref to { bus, me, invoke(req) } once ready, note: what went wrong, ready }. `ask` and `extra` (more
// shellDeps options, e.g. NAP-DM's) are read once, at mount: pass functions that read refs for anything that changes.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps } from "./shell-deps.js"
import { firstParty } from "./first-party.js"

export const READY_WAIT_MS = 5000

export function usePaneNapplet(ctx, host, { dTag, actions = {}, handlers = [], ask = async () => false, extra = {}, onReady } = {}) {
  const [note, setNote] = useState("")
  const [ready, setReady] = useState(false)
  const live = useRef(null)
  const grants = useMemo(() => grantStore(localStorage, ctx.session.pubkey), [ctx.session.pubkey])
  useEffect(() => {
    const bus = createBus(), me = { dTag: "shell", send: () => {} }
    const offs = handlers.map(h => bus.register(h))
    const n = firstParty(dTag)
    let mounted = null, gone = false
    setReady(false)
    ;(async () => {
      try {
        const r = await openNapplet({
          html: n.html, name: n.dTag, title: n.title, firstParty: true, domains: n.domains, container: host.current, grants,
          consent: async () => null, // first-party: never asked
          makeDeps: saveGrant => shellDeps(ctx, { ask, saveGrant, bus, ...extra }),
          onRevoke: why => { if (!gone && why !== "closed by shell") setNote(`${n.title} closed: ${why}.`) },
        })
        mounted = r.mounted
        if (gone) return mounted.close()
        await Promise.race([mounted.napplet.ready, new Promise(res => setTimeout(res, READY_WAIT_MS))])
        if (gone) return
        for (const [archetype, acts] of Object.entries(actions)) offs.push(bus.register({ id: n.dTag, title: n.title, archetype, actions: acts, conventions: [], open: async () => mounted.napplet }))
        live.current = { bus, me, invoke: req => bus.invoke(me, req) }
        setReady(true)
        onReady?.(live.current)
      } catch (e) { if (!gone) setNote(`${n.title} couldn't open: ${e?.message ?? e}`) }
    })()
    return () => { gone = true; offs.forEach(f => f()); mounted?.close(); live.current = null }
  }, [ctx, grants])
  return { live, note, ready }
}
