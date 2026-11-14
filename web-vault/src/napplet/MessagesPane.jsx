// Messages as the Messages napplet (plan P7), when the napplet switch is on (flag.js). The shell keeps the whole DM
// stack: this pane runs the classic loading and live watching (MessagesScreen.jsx useMessages), shows the classic
// signer, AUTH and Open more lines above the napplet (they are about your signer, which the napplet never sees), and
// answers NAP-DM from that state (dm-dispatch.js). `open`: a conversation to show first (#/dm/<pubkey>), handed over
// by intent (napplet:dm/open).
import { useEffect, useRef } from "preact/hooks"
import { useBlocks } from "../components/useBlocks.js"
import { useDmTrust } from "../components/useDmTrust.js"
import { unreadCounts } from "../net/dm-read.js"
import { fetchProfiles, onProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { useMessages, SignerTrouble, AuthTrouble, OpenMore, BunkerNote } from "../screens/MessagesScreen.jsx"
import { MESSAGES_DTAG } from "./first-party.js"
import { usePaneNapplet } from "./usePaneNapplet.js"
import { VaultPagesMenu } from "../screens/VaultPagesMenu.jsx"
import { searchName } from "../screens/MessagesTools.jsx"
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
  const ctxRef = useRef(ctx), looked = useRef(new Set())
  ctxRef.current = ctx
  const openRef = useRef(open)
  openRef.current = open
  const { live, note } = usePaneNapplet(ctx, host, {
    dTag: MESSAGES_DTAG, actions: { dm: ["open", "refresh"] },
    extra: { dm: {
      blocked: () => blockedRef.current, trusted: () => trustedRef.current, unread: msgs => unreadCounts(msgs, me, blockedRef.current),
      // Search by the names the classic page searches by; your follows' photos load without a tap, as there; a
      // brand-new conversation's name is looked up as the classic thread looks it up.
      searchName, follows: pk => ctxRef.current.account.follows.includes(pk),
      // Once per person while the page is up: a key with no profile anywhere would otherwise be asked for again on
      // every refresh the napplet gets.
      lookup: pks => { const fresh = pks.filter(pk => !looked.current.has(pk)); fresh.forEach(pk => looked.current.add(pk)); if (fresh.length) fetchProfiles(ctxRef.current.vault, fresh, uniq([...ctxRef.current.account.relays.read, ...PROFILE_RELAYS, ...DEFAULT_RELAYS])).catch(() => {}) },
    } },
    onReady: l => {
      if (HEX.test(openRef.current ?? "")) l.invoke({ archetype: "dm", action: "open", payload: { pubkey: openRef.current } })
      // Names that landed before the napplet was up: one redraw now; later arrivals redraw through onProfiles below.
      l.invoke({ archetype: "dm", action: "refresh", payload: {} })
    },
  })

  // Names and pictures for the people you talk with, as the classic page fetches them; the napplet redraws when
  // they land (napplet:dm/refresh), at most every second.
  // Not a memo on `messages`: the DM state fills the same Map in place (net/dms.js), so its identity never changes.
  const peers = uniq([...messages.values()].map(m => m.peer)).sort()
  useEffect(() => { if (peers.length) fetchProfiles(ctx.vault, peers, uniq([...ctx.account.relays.read, ...PROFILE_RELAYS, ...DEFAULT_RELAYS])).catch(() => {}) }, [peers.join()])
  useEffect(() => {
    let t = null
    const off = onProfiles(() => { if (t) return; t = setTimeout(() => { t = null; const l = live.current; if (l) l.invoke({ archetype: "dm", action: "refresh", payload: {} }) }, 1000) })
    return () => { off(); clearTimeout(t) }
  }, [])

  const sent = useRef(open)
  useEffect(() => {
    if (open === sent.current) return
    sent.current = open
    const l = live.current
    if (l && HEX.test(open ?? "")) l.invoke({ archetype: "dm", action: "open", payload: { pubkey: open } })
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
