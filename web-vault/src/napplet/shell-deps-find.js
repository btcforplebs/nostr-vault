// What a DM send left in the DM state, for NAP-DM (shell-deps.js). Its own file so node tests load it alone.
/** The newest message of mine to `peer` with this text, sent or (`failed`) not: what sendMessage left in the DM state.
 *  `before` = the ids that were already there, so re-sending the same text never answers with the older message. */
export function findMine(messages, me, peer, text, failed = false, before = new Set()) {
  let best = null
  for (const m of messages.values()) if (!before.has(m.id) && m.from === me && m.peer === peer && m.content === text && !m.pending && !!m.failed === failed && (!best || m.at >= best.at)) best = m
  return best
}

/** The newest message of mine to `peer` that wasn't there `before`, sent or (`failed`) not, whatever its text: what a
 *  Try again left (a photo's text changes once it uploads). */
export function newestMine(messages, me, peer, failed = false, before = new Set()) {
  let best = null
  for (const m of messages.values()) if (!before.has(m.id) && m.from === me && m.peer === peer && !m.pending && !!m.failed === failed && (!best || m.at >= best.at)) best = m
  return best
}

