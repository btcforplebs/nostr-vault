// The web-of-trust gate every napplet read passes (Logen, nv-3.0 2026-11-14 13:41Z: napplets only ever see what
// already passed your web of trust). The web is the reader feeds' Global one (readers/trust.js globalTrust): you, your
// follows and the people they follow. No follows means no web, and the gate fails closed: only your own events pass.
// One exception, the user's own choice: an emoji set (30030) that their own emoji list (10030) names, so the Emoji
// napplet still draws sets made by people outside the web. Pure, so node tests load it.

/** -> ev => bool. `trust`: Set of pubkeys or null (no web). `named`: Set of "30030:<pubkey>:<d>" from the user's 10030. */
export function wotGate({ me, trust, named = new Set() }) {
  return ev => {
    if (!ev || typeof ev.pubkey !== "string") return false
    if (ev.pubkey === me || trust?.has(ev.pubkey)) return true
    if (ev.kind !== 30030) return false
    const d = (ev.tags ?? []).find(t => t?.[0] === "d")?.[1] ?? ""
    return named.has(`30030:${ev.pubkey}:${d}`)
  }
}

/** The emoji sets a 10030 list names ("a" tags 30030:<pubkey>:<d>). */
export function namedSets(list) {
  const out = new Set()
  for (const t of list?.tags ?? []) if (t?.[0] === "a" && /^30030:[0-9a-f]{64}:/.test(t[1] ?? "")) out.add(t[1])
  return out
}
