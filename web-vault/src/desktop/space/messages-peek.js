// The Messages peek panel's rules (no styles, so tests can import it). The panel draws the user's inbox beside whatever
// is open: unread chats first, then the rest, each with its last line. It reads only what the Messages screen has
// already opened this session (net/dms.js getMessages): nothing here asks the signer or publishes.
import { conversations } from "../../net/dms.js"
import { splitConversations } from "../../net/dm-trust.js"

/** Chats the panel draws at most. */
export const PEEK_ROWS = 12

/**
 * The inbox for the panel -> [{ peer, last, unread }]. Requests (people outside the Web of Trust the user never wrote
 * to) and blocked people are left out, as they are from the unread badge. Unread chats come first, newest first, then
 * the read ones, newest first; at most `max`.
 */
export function peekRows(messages, me, blocked, trusted, counts, max = PEEK_ROWS) {
  const { inbox } = splitConversations(conversations(messages, blocked), messages, me, trusted)
  const rows = inbox.map(c => ({ peer: c.peer, last: c.last, unread: counts.get(c.peer) ?? 0 }))
  const unread = rows.filter(r => r.unread > 0), read = rows.filter(r => !r.unread)
  return [...unread, ...read].slice(0, max)
}

/** Whether the Messages screen has opened this account's messages this session (or is opening them): until then the
 *  panel has nothing to draw, and says where to open them. Another account's messages (just switched) count as none. */
export const peekOpen = (state, me) => !!me && state.pubkey === me && (state.loaded || state.messages.size > 0)
