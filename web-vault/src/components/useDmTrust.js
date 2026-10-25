import { useEffect, useState } from "preact/hooks"
import { followLists } from "../net/wot.js"
import { trustedWeb } from "../net/notifications.js"
import { requestPeers } from "../net/dm-trust.js"

// The trust set Messages splits on (net/dm-trust.js): Notifications' (trustedWeb over the follows' contact lists,
// wot.js followLists, whose cache the Web of Trust tab, Popular and Notifications share, so no list is fetched twice).
// Empty until the lists come back, which keeps strangers out of the inbox meanwhile. The last set is kept here so the
// badge and the screens agree as soon as one of them has it.
let latest = { me: null, key: "", trusted: new Set() }
const listeners = new Set()

export function useDmTrust(ctx) {
  const me = ctx.session?.pubkey ?? null
  const follows = ctx.account?.follows ?? []
  const key = `${me}:${follows.length}:${follows[0] ?? ""}:${follows[follows.length - 1] ?? ""}`
  const [, setTick] = useState(0)
  useEffect(() => {
    const bump = () => setTick(t => t + 1)
    listeners.add(bump)
    return () => listeners.delete(bump)
  }, [])
  useEffect(() => {
    if (!me || (latest.me === me && latest.key === key && latest.trusted.size)) return
    followLists(me, follows).then(lists => {
      latest = { me, key, trusted: trustedWeb(follows, lists) }
      for (const cb of listeners) cb()
    }).catch(() => {})
  }, [key])
  return latest.me === me ? latest.trusted : new Set()
}

/** Who to leave out of unread counts: blocked people and Requests (a request never raises a badge). */
export const hiddenFromUnread = (messages, me, blocked, trusted) => new Set([...blocked, ...requestPeers(messages, me, trusted)])
