// How many replies in a thread the Reader napplet isn't shown because their authors are outside your web (bug run,
// group 8). Napplets only ever see what passed your web (wot-gate.js), so the Reader gets the number, never the
// notes: the classic thread's "Show N replies from outside your web" line, without the Show. Blocked people aren't
// counted (they aren't shown in the classic thread either).
const HEX = /^[0-9a-f]{64}$/
export const OUTSIDE_LIMIT = 300

/** `deps`: shell-deps.js (vaultQuery, netQuery, wotGate, blocked, verify, pubkey). -> the count, 0 on any failure. */
export async function outsideReplies(rootId, deps) {
  if (!HEX.test(rootId ?? "")) return 0
  const f = [{ kinds: [1], "#e": [rootId], limit: OUTSIDE_LIMIT }]
  const [haven, net, gate] = await Promise.all([
    deps.vaultQuery(f).catch(() => []), deps.netQuery(f).catch(() => []),
    deps.wotGate().catch(() => ev => ev?.pubkey === deps.pubkey), // no web: only your own pass, as every napplet read
  ])
  const blocked = deps.blocked?.() ?? new Set()
  const ids = new Set()
  for (const ev of [...haven, ...net]) {
    if (ids.has(ev?.id) || ev?.kind !== 1 || !(ev.tags ?? []).some(t => t[0] === "e" && t[1] === rootId)) continue
    if (gate(ev) || blocked.has(ev.pubkey) || !deps.verify(ev)) continue
    ids.add(ev.id)
  }
  return ids.size
}
