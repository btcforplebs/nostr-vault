import { useEffect, useState } from "preact/hooks"
import { getMessages, onMessages } from "../net/dms.js"
import { onRead, unreadTotal } from "../net/dm-read.js"
import { useBlocks } from "./useBlocks.js"
import { hiddenFromUnread, useDmTrust } from "./useDmTrust.js"

/** Unread messages for the signed-in account, blocked people and Requests left out (DMService.totalUnreadCount), re-counted as
 *  messages land or are read. Counts only what Messages has opened: nothing here asks the signer, so the badge stays
 *  0 until Messages has loaded once this session. */
export function useUnreadTotal(ctx) {
  const me = ctx.session?.pubkey
  const { blocked } = useBlocks(ctx)
  const trusted = useDmTrust(ctx)
  const [, setTick] = useState(0)
  useEffect(() => {
    const bump = () => setTick(t => t + 1)
    const offM = onMessages(bump), offR = onRead(bump)
    return () => { offM(); offR() }
  }, [])
  return accountUnread(getMessages(), me, blocked, undefined, trusted)
}

/** The badge's number: messages loaded for another account (just switched) count as none, and so do Requests
 *  (net/dm-trust.js): a stranger's message never raises the badge. `trusted` empty: only conversations you wrote in. */
export const accountUnread = (state, me, blocked, opts, trusted = new Set()) =>
  (me && state.pubkey === me ? unreadTotal(state.messages, me, hiddenFromUnread(state.messages, me, blocked, trusted), opts) : 0)

/** "3", "99+": the badge's text. */
export const badgeCount = n => (n > 99 ? "99+" : String(n))
