import { useEffect, useRef } from "preact/hooks"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { receiptTrust } from "../net/zaps.js"
import { fetchInbound, fetchFollowerLists, readInbound, readOwn, readLists, keepLists, mergeLists } from "../net/vault-lists.js"
import { readSeen, onSeen } from "../net/vault-new.js"
import { getProfile, fetchProfiles } from "../net/profiles.js"
import { getBlocks } from "../net/blocks.js"
import { useDmTrust } from "./useDmTrust.js"
import {
  POLL_MS, notifyOn, permission, readMark, writeMark, readSince, unreadFrom, vaultLines, unreadLines, titleWith, noticesFor, lookingAtVault,
} from "../net/notify-watch.js"

const nameOf = pk => getProfile(pk)?.name ?? ""

/**
 * While the app is open for an account: asks the user's relays for new Vault activity every POLL_MS (a background tab
 * too; browsers slow its timers to about once a minute, which this already is), keeps the count of lines newer than
 * the Vault list's seen mark in the tab's title, and raises a browser notification for each new line when the user
 * turned them on. Pull only, and only while a page is open.
 */
export function useNotifyWatch(ctx) {
  const me = ctx.session?.pubkey
  const relays = uniq([...(ctx.account?.relays?.read ?? []), ...DEFAULT_RELAYS])
  const live = useRef(ctx)
  live.current = ctx
  const network = useRef(new Set())
  network.current = useDmTrust(ctx) // the Vault list's network: notes from outside it don't count or pop up
  useEffect(() => {
    if (!me) return
    const base = document.title.replace(/^\(\d+\+?\) /, "")
    let stopped = false, timer = null, lines = []
    let mark = readMark(me)
    const since = readSince(me)
    const from = () => unreadFrom(readSeen(me)?.activity ?? 0, since)
    const show = () => { document.title = titleWith(unreadLines(lines, from()).length, base) }
    const rebuild = async () => {
      const { vault } = live.current
      const [inbound, own] = await Promise.all([readInbound(vault, me).catch(() => []), readOwn(vault, me).catch(() => [])])
      lines = vaultLines({ inbound, own, lists: readLists(me), me, blocked: getBlocks().pubkey === me ? getBlocks().blocked : new Set(), trusted: network.current })
      show()
    }
    const raise = async () => {
      const seenAt = from()
      const fresh = lines.filter(r => r.created_at > mark && r.created_at > seenAt)
      if (!fresh.length) return
      // Names for the text, the faces' profiles the list will draw anyway.
      await fetchProfiles(live.current.vault, uniq(fresh.flatMap(r => r.actors.slice(0, 2))), relays).catch(() => {})
      const out = noticesFor(lines, { mark, seenAt, nameOf })
      mark = out.mark
      writeMark(me, mark)
      if (!notifyOn() || permission() !== "granted" || lookingAtVault()) return
      for (const n of out.notices) {
        try {
          const note = new Notification(n.title, { body: n.body, tag: n.tag, icon: "./icon.svg" })
          note.onclick = () => { try { window.focus() } catch {} location.hash = n.href; note.close() }
        } catch {} // Chrome on Android only shows notifications from a service worker: nothing to do there.
      }
    }
    const poll = async () => {
      if (stopped) return
      const { vault } = live.current
      const after = Math.max(0, mark - 60)
      if (navigator.onLine !== false) {
        await Promise.allSettled([
          fetchInbound(vault, me, relays, { since: after, limit: 100, trust: receiptTrust(live.current) }),
          fetchFollowerLists(me, relays, { since: after, limit: 100, on: fresh => keepLists(me, mergeLists(readLists(me), fresh, me)) }),
        ])
      }
      if (stopped) return
      await rebuild().catch(() => {})
      await raise().catch(() => {})
      if (!stopped) timer = setTimeout(poll, POLL_MS)
    }
    rebuild().catch(() => {}).then(poll)
    // A look at the Vault list moves its seen mark: the title's count follows at once.
    const offSeen = onSeen(show)
    addEventListener("hashchange", show)
    return () => { stopped = true; clearTimeout(timer); offSeen(); removeEventListener("hashchange", show); document.title = base }
  }, [me, relays.join(" ")])
}

/** useNotifyWatch as an element, for the signed-in part of the app. */
export function NotifyWatch({ ctx }) {
  useNotifyWatch(ctx)
  return null
}
