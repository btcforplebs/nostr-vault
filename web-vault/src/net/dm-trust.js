// Who reaches the Messages inbox (the iPhone's DMTrust). A gift-wrapped DM is signed by a throwaway key, so every
// wrap tagged to the user arrives whoever sent it; only the opened message names the person, and this check runs on
// that real sender (dms.js `peer`).
//
// A conversation is in the inbox when the other person is in the user's Web of Trust (the user, their follows and
// the people their follows follow: notifications.js trustedWeb over wot.js followLists, the set Notifications uses)
// or when the user has written in it. Following the user is not trust: anyone can follow anyone. Everyone else waits
// under Requests, unread but silent (no badge), and answering moves the conversation into the inbox.
//
// Fails closed: with no trust graph yet (an empty set), only conversations the user wrote in reach the inbox.

/** Whether a conversation with `counterparty` belongs in the inbox. `trusted` and `own` are Sets of hex keys. */
export function isInbox(counterparty, youWrote, trusted, own) {
  if (youWrote) return true
  const key = String(counterparty ?? "").toLowerCase()
  for (const o of own) if (String(o).toLowerCase() === key) return true
  return trusted.has(key) || trusted.has(counterparty)
}

/** Splits conversations into the inbox and Requests, keeping their order. -> { inbox, requests } */
export function split(conversations, trusted, own, counterparty, youWrote) {
  const inbox = [], requests = []
  for (const c of conversations) (isInbox(counterparty(c), youWrote(c), trusted, own) ? inbox : requests).push(c)
  return { inbox, requests }
}

/** The peers of conversations the user wrote in: any message from `me` there. */
export function wroteIn(messages, me) {
  const out = new Set()
  for (const m of messages.values()) if (m.from === me) out.add(m.peer)
  return out
}

/** The peers whose conversations are Requests, from the decrypted messages (dms.js state.messages). */
export function requestPeers(messages, me, trusted) {
  const wrote = wroteIn(messages, me)
  const own = new Set([me])
  const out = new Set()
  for (const m of messages.values()) if (!isInbox(m.peer, wrote.has(m.peer), trusted, own)) out.add(m.peer)
  return out
}

/** dms.js conversations rows split into the inbox and Requests. */
export const splitConversations = (list, messages, me, trusted) => {
  const wrote = wroteIn(messages, me)
  return split(list, trusted, new Set([me]), c => c.peer, c => wrote.has(c.peer))
}
