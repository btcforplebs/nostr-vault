import { useEffect, useRef, useState } from "preact/hooks"
import { getMessages, onMessages, loadMessages, loadedRecently, watchMessages } from "../net/dms.js"
import { inboxRelays } from "../screens/MessagesScreen.jsx"
import { getBlocks } from "../net/blocks.js"
import { getProfile, fetchProfiles } from "../net/profiles.js"
import { notifyOn, onNotifyPref, permission } from "../net/notify-watch.js"
import { readTypes, onTypes } from "../net/notify-prefs.js"
import { readDmMark, writeDmMark, dmNotices, dmOnScreen } from "../net/dm-notify.js"
import { showNotice } from "../net/notify-show.js"
import { hiddenFromUnread, useDmTrust } from "./useDmTrust.js"

const nameOf = pk => getProfile(pk)?.name ?? ""
const wanted = () => notifyOn() && permission() === "granted" && readTypes().dms

/**
 * Message notifications while the tab is open: with browser notifications and Messages on, the inbox is read and
 * listened to as the Messages screen does it (dms.js loadMessages + watchMessages, so the signer opens new messages
 * while the tab is open, and the Vault tab's dot counts them), and each new message from someone in your network
 * raises "Message from X". Off, nothing here asks the signer.
 */
export function useDmNotify(ctx) {
  const me = ctx.session?.pubkey
  const [on, setOn] = useState(wanted)
  useEffect(() => { const f = () => setOn(wanted()); const a = onNotifyPref(f), b = onTypes(f); return () => { a(); b() } }, [])
  const trusted = useRef(new Set())
  trusted.current = useDmTrust(ctx)
  const live = useRef(ctx)
  live.current = ctx
  useEffect(() => {
    if (!me || !on || ctx.signer?.readOnly) return
    let mark = readDmMark(me), stop = () => {}, stopped = false
    const check = async () => {
      const s = getMessages()
      if (s.pubkey !== me) return
      const blocked = getBlocks().pubkey === me ? getBlocks().blocked : new Set()
      const hidden = hiddenFromUnread(s.messages, me, blocked, trusted.current)
      const peers = [...new Set([...s.messages.values()].filter(m => m.at > mark && m.from !== me).map(m => m.peer))]
      if (peers.length) await fetchProfiles(live.current.vault, peers, live.current.account?.relays?.read ?? []).catch(() => {})
      const out = dmNotices(getMessages().messages, me, { mark, hidden, onScreen: dmOnScreen(), nameOf })
      if (out.mark !== mark) { mark = out.mark; writeDmMark(me, mark) }
      if (wanted()) for (const n of out.notices) await showNotice(n)
    }
    const off = onMessages(() => { check().catch(() => {}) })
    ;(async () => {
      const relays = await inboxRelays(live.current).catch(() => [])
      if (stopped) return
      if (!loadedRecently(me, { within: 10 * 60_000 })) await loadMessages(live.current, relays).catch(() => {})
      if (!stopped) stop = watchMessages(live.current, relays)
    })()
    return () => { stopped = true; off(); stop() }
  }, [me, on])
}
