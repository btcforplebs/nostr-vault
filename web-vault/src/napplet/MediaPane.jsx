// Vault › Media as the Media napplet (plan P5), when the napplet switch is on (flag.js): your media servers' files,
// listed, copied and deleted through NAP-BLOSSOM (blossom-dispatch.js: the shell signs every Blossom auth) with
// pictures and video as bytes from the shell. The shell asks before any delete, ours too; that sheet is here.
// `filter`: the Vault's Media pill (all, photos, videos, gifs), handed to the napplet by intent (napplet:media/open).
// Switch off, or the "In your notes" pill: the classic page (BlossomGallery.jsx, VaultScreen.jsx).
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps } from "./shell-deps.js"
import { firstParty, MEDIA_DTAG } from "./first-party.js"
import { askWords } from "./consent-words.js"
import "./napplet.css"

export function MediaPane({ ctx, filter = "all" }) {
  const host = useRef(null)
  const [note, setNote] = useState("")
  const [asking, setAsking] = useState(null) // { words, resolve }
  const grants = useMemo(() => grantStore(localStorage, ctx.session.pubkey), [ctx.session.pubkey])
  const live = useRef(null) // { bus, me }
  const filterRef = useRef(filter)
  filterRef.current = filter

  useEffect(() => {
    const bus = createBus()
    const me = { dTag: "shell", send: () => {} }
    let mounted = null, gone = false, off = null
    const ask = ({ napplet, what, detail }) => new Promise(resolve => setAsking({ words: askWords(what, napplet, detail), resolve }))
    ;(async () => {
      try {
        const n = firstParty(MEDIA_DTAG)
        const r = await openNapplet({
          html: n.html, name: n.dTag, title: n.title, firstParty: true, domains: n.domains, container: host.current, grants,
          consent: async () => null, // first-party: never asked
          makeDeps: saveGrant => shellDeps(ctx, { ask, saveGrant, bus }),
          onRevoke: why => { if (!gone && why !== "closed by shell") setNote(`Media closed: ${why}.`) },
        })
        mounted = r.mounted
        if (gone) return mounted.close()
        await Promise.race([mounted.napplet.ready, new Promise(res => setTimeout(res, 5000))])
        off = bus.register({ id: "nv-media", title: "Media", archetype: "media", actions: ["open"], conventions: [], open: async () => mounted.napplet })
        live.current = { bus, me }
        if (filterRef.current !== "all") bus.invoke(me, { archetype: "media", action: "open", payload: { filter: filterRef.current } })
      } catch (e) { if (!gone) setNote(`Media couldn't open: ${e?.message ?? e}`) }
    })()
    return () => { gone = true; off?.(); mounted?.close(); live.current = null }
  }, [ctx, grants])

  const sent = useRef(filter)
  useEffect(() => {
    if (filter === sent.current) return
    sent.current = filter
    const l = live.current
    if (l) l.bus.invoke(l.me, { archetype: "media", action: "open", payload: { filter } })
  }, [filter])

  const answer = yes => { asking?.resolve(yes); setAsking(null) }
  return (
    <div class="media-pane">
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host media-host" ref={host} />
      {asking && (
        <Dialog label={asking.words.title} onClose={() => answer(false)}>
          <h3>{asking.words.title}</h3>
          {asking.words.body && <p class="napplet-preview">{asking.words.body}</p>}
          <div class="mod-row">
            <button type="button" class="napplet-danger" onClick={() => answer(true)}>{asking.words.yes}</button>
            <button type="button" onClick={() => answer(false)}>{asking.words.no}</button>
          </div>
        </Dialog>
      )}
    </div>
  )
}
