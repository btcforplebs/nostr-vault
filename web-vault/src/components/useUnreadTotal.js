import { useEffect, useState } from "preact/hooks"
import { getMessages, onMessages } from "../net/dms.js"
import { onRead, unreadTotal } from "../net/dm-read.js"
import { useBlocks } from "./useBlocks.js"

/** Unread messages for the signed-in account, blocked people left out (DMService.totalUnreadCount), re-counted as
 *  messages land or are read. Counts only what Messages has opened: nothing here asks the signer, so the badge stays
 *  0 until Messages has loaded once this session. */
export function useUnreadTotal(ctx) {
  const me = ctx.session?.pubkey
  const { blocked } = useBlocks(ctx)
  const [, setTick] = useState(0)
  useEffect(() => {
    const bump = () => setTick(t => t + 1)
    const offM = onMessages(bump), offR = onRead(bump)
    return () => { offM(); offR() }
  }, [])
  return accountUnread(getMessages(), me, blocked)
}

/** The badge's number: messages loaded for another account (just switched) count as none. */
export const accountUnread = (state, me, blocked, opts) => (me && state.pubkey === me ? unreadTotal(state.messages, me, blocked, opts) : 0)

/** "3", "99+": the badge's text. */
export const badgeCount = n => (n > 99 ? "99+" : String(n))
