// Messages as the Messages napplet (plan P7), when the napplet switch is on (flag.js). The shell keeps the whole DM
// stack: this pane runs the classic loading and live watching (MessagesScreen.jsx useMessages), shows the classic
// signer, AUTH and Open more lines above the napplet (they are about your signer, which the napplet never sees), and
// answers NAP-DM from that state (dm-dispatch.js). `open`: a conversation to show first (#/dm/<pubkey>), handed over
// by intent (napplet:dm/open).
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { useBlocks } from "../components/useBlocks.js"
import { useDmTrust } from "../components/useDmTrust.js"
import { unreadCounts } from "../net/dm-read.js"
import { fetchProfiles, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { useMessages, SignerTrouble, AuthTrouble, OpenMore, BunkerNote } from "../screens/MessagesScreen.jsx"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps } from "./shell-deps.js"
import { firstParty, MESSAGES_DTAG } from "./first-party.js"
import { VaultPagesMenu } from "../screens/VaultPagesMenu.jsx"
import "./napplet.css"

const HEX = /^[0-9a-f]{64}$/

export function MessagesPane({ ctx, open = null, vaultMenu = false }) {
  const me = ctx.session.pubkey
  const { trouble, retry, refresh, more, messages } = useMessages(ctx)
  const { blocked } = useBlocks(ctx)
  const trusted = useDmTrust(ctx)
  const blockedRef = useRef(blocked), trustedRef = useRef(trusted)
  blockedRef.current = blocked; trustedRef.current = trusted
  const host = useRef(null)
  const [note, setNote] = useState("")
  const grants = useMemo(() => grantStore(localStorage, me), [me])
  const live = useRef(null)
  const openRef = useRef(open)
  openRef.current = open

  useEffect(() => {
    const bus = createBus(), shell = { dTag: "shell", send: () => {} }
    let mounted = null, gone = false, off = null
    const dm = { blocked: () => blockedRef.current, trusted: () => trustedRef.current, unread: msgs => unreadCounts(msgs, me, blockedRef.current) }
    ;(async () => {
      try {
        const n = firstParty(MESSAGES_DTAG)
        const r = await openNapplet({
          html: n.html, name: n.dTag, title: n.title, firstParty: true, domains: n.domains, container: host.current, grants,
          consent: async () => null,
          makeDeps: saveGrant => shellDeps(ctx, { ask: async () => false, saveGrant, bus, dm }),
          onRevoke: why => { if (!gone && why !== "closed by shell") setNote(`Messages closed: ${why}.`) },
        })
        mounted = r.mounted
        if (gone) return mounted.close()
        await Promise.race([mounted.napplet.ready, new Promise(res => setTimeout(res, 5000))])
        off = bus.register({ id: "nv-messages", title: "Messages", archetype: "dm", actions: ["open", "refresh"], conventions: [], open: async () => mounted.napplet })
        live.current = { bus, me: shell }
        if (HEX.test(openRef.current ?? "")) bus.invoke(shell, { archetype: "dm", action: "open", payload: { pubkey: openRef.current } })
        // Names that landed before the napplet was up: one redraw now; later arrivals redraw through onProfiles below.
        bus.invoke(shell, { archetype: "dm", action: "refresh", payload: {} })
      } catch (e) { if (!gone) setNote(`Messages couldn't open: ${e?.message ?? e}`) }
    })()
    return () => { gone = true; off?.(); mounted?.close(); live.current = null }
  }, [ctx, grants])

  // Names and pictures for the people you talk with, as the classic page fetches them; the napplet redraws when
  // they land (napplet:dm/refresh), at most every second.
  // Not a memo on `messages`: the DM state fills the same Map in place (net/dms.js), so its identity never changes.
  const peers = uniq([...messages.values()].map(m => m.peer)).sort()
  useEffect(() => { if (peers.length) fetchProfiles(ctx.vault, peers, uniq([...ctx.account.relays.read, ...PROFILE_RELAYS, ...DEFAULT_RELAYS])).catch(() => {}) }, [peers.join()])
  useEffect(() => {
    let t = null
    const off = onProfiles(() => { if (t) return; t = setTimeout(() => { t = null; const l = live.current; if (l) l.bus.invoke(l.me, { archetype: "dm", action: "refresh", payload: {} }) }, 1000) })
    return () => { off(); clearTimeout(t) }
  }, [])

  const sent = useRef(open)
  useEffect(() => {
    if (open === sent.current) return
    sent.current = open
    const l = live.current
    if (l && HEX.test(open ?? "")) l.bus.invoke(l.me, { archetype: "dm", action: "open", payload: { pubkey: open } })
  }, [open])

  return (
    <main class="screen messages-pane">
      {/* The phone's Messages page wears the Vault menu, as the classic one does; the desktop column doesn't. */}
      {vaultMenu && <header class="screen-head"><VaultPagesMenu ctx={ctx} current="messages" /><h2 class="sr-only">Messages</h2></header>}
      <BunkerNote ctx={ctx} />
      <SignerTrouble trouble={trouble} retry={retry} />
      <AuthTrouble refresh={refresh} />
      <OpenMore ctx={ctx} more={more} />
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host messages-host" ref={host} />
    </main>
  )
}
