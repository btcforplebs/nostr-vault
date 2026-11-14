// Compose's emoji panel when napplets are on (flag.js): the Emoji napplet (napplets/emoji), opened by intent through
// the shell's bus (emoji-intent.js) and answered by the same runtime as the shell page. Picks land in the note; the
// panel stays open for more until Done. Its own lazy chunk (lazy-screens.js), so compose doesn't carry the runtime.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Dialog } from "../components/Moderation.jsx"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps } from "./shell-deps.js"
import { firstParty, EMOJI_DTAG } from "./first-party.js"
import { composeEmoji } from "./emoji-intent.js"
import "./napplet.css"

export function ComposeEmoji({ ctx, onPick, onClose }) {
  const host = useRef(null)
  const [note, setNote] = useState("")
  const grants = useMemo(() => grantStore(localStorage, ctx.session.pubkey), [ctx.session.pubkey])
  const pickRef = useRef(onPick)
  pickRef.current = onPick

  useEffect(() => {
    const bus = createBus()
    let mounted = null, gone = false
    const open = async () => {
      if (mounted) return mounted.napplet
      const n = firstParty(EMOJI_DTAG)
      const r = await openNapplet({
        html: n.html, name: n.dTag, title: n.title, firstParty: true, domains: n.domains, container: host.current, grants,
        consent: async () => null, // first-party: never asked
        makeDeps: saveGrant => shellDeps(ctx, { ask: async () => false, saveGrant, bus }),
        onRevoke: why => { if (!gone && why !== "closed by shell") setNote(`Emoji closed: ${why}.`) },
      })
      mounted = r.mounted
      if (gone) mounted.close()
      // Delivered once the napplet has said hello (its port is up); until then the bus's send would go nowhere.
      await Promise.race([mounted.napplet.ready, new Promise(r => setTimeout(r, 5000))])
      return mounted.napplet
    }
    const wire = composeEmoji({ bus, open, onPick: p => pickRef.current(p) })
    wire.ask().then(r => { if (!r?.ok && !gone) setNote(`Emoji couldn't open: ${r?.error ?? "unknown"}.`) })
    return () => { gone = true; wire.close(); mounted?.close() }
  }, [ctx, grants])

  return (
    <Dialog label="Add emoji" onClose={onClose}>
      <div class="info-head"><h3>Add Emoji</h3><button type="button" class="small" onClick={onClose}>Done</button></div>
      {note && <p class="muted small" role="status">{note}</p>}
      <div class="napplet-host compose-emoji-host" ref={host} />
    </Dialog>
  )
}
