// What a napplet may see and sign. Pure, so node tests load it. Logen's rules (nv-3.0, 2026-11-14; plan
// RESEARCH/NV_WEB_NAPPLET_PLAN.md §8):
//   - Vault-private data goes to our own napplets only (first-party: built into this app, matched by artifact hash,
//     trusted like the screens they replace). An outside napplet never gets it, whatever it is granted (15:20Z).
//   - Every napplet, ours too, reads relays only through Haven and sees only what passed the web of trust
//     (13:41Z): dispatch.js read/subscribe, wot-gate.js.
//
// "Vault-private" here is:
//   - Haven's own routes beyond the public feed cache: the user's events (/) and what others sent them (/inbox);
//   - private kinds wherever they come from: DMs and gift wraps, the DM relay list, app data, mute lists, wallet;
//   - the user's mute and block lists (identity.getMutes / getBlocked);
//   - the vault's own files and media servers (blossom), and DMs (dm).
// An outside napplet reads Haven's public feed cache and, through the shell, the network: WoT-gated, private kinds
// removed. The shell's block list applies to every napplet.

/** Kinds no outside napplet ever sees, even from a public relay. */
export const PRIVATE_KINDS = new Set([
  4, 13, 14, 15, 1059, 1060, // DMs, seals, gift wraps (NIP-04, NIP-17, NIP-59)
  10000, 10050, 30078, // mute list, DM relays, app data
  7374, 7375, 7376, 17375, 37375, 13194, 23194, 23195, // wallet: cashu (NIP-60) and NWC (NIP-47)
])

/** Kinds no napplet may have signed, ours included: one bad list wipes the account's follows or relays. Lists are
 *  edited only by the app's own guarded editors (test/user-list-sign-guard.test.mjs); a napplet asks the shell.
 *  10030/30030: the emoji list and emoji sets (Tara, 2026-11-14): the Emoji napplet only reads them. */
export const ACCOUNT_KINDS = new Set([0, 3, 10000, 10002, 10006, 10030, 10050, 10063, 30030])

/** Kinds no napplet ever gets signed, ours included: a credential (relay AUTH, Blossom auth, HTTP auth, NWC), or the
 *  account's end (62, NIP-62 Request to Vanish). */
export const NEVER_SIGN = new Set([22242, 24242, 27235, 13194, 23194, 23195, 62])

/** Kinds a napplet may not delete either (kind 5 naming them in `a`/`k`): deleting the follow list wipes it too. */
export const protectedKind = k => ACCOUNT_KINDS.has(k) || NEVER_SIGN.has(k)

/** A kind 5's targets: `e` ids, `a` addresses (with their kind), `k` kinds. Malformed numbers count as NaN. */
export function deletionTargets(template) {
  const tags = template?.tags ?? []
  const ids = tags.filter(t => t[0] === "e" && t[1]).map(t => t[1])
  const addrs = tags.filter(t => t[0] === "a" && t[1]).map(t => t[1])
  const kinds = [...addrs.map(a => Number(a.split(":")[0])), ...tags.filter(t => t[0] === "k").map(t => Number(t[1]))]
  return { ids, addrs, kinds, count: ids.length + addrs.length }
}

/** A napplet's grant: what the user said yes to. First-party napplets get everything they ask for. */
export function defaultGrant({ firstParty = false, domains = [] } = {}) {
  return { firstParty, domains: [...domains], publish: firstParty ? "allow" : "ask", notify: firstParty }
}

/** An outside napplet's grant as the shell uses it, from whatever was saved (an older build kept a private-data
 *  switch): never first-party, never private data, every post asked. Only a yes to notifications carries over. */
export function outsideGrant(saved) {
  const domains = Array.isArray(saved?.domains) ? saved.domains.filter(d => typeof d === "string") : []
  return { ...defaultGrant({ domains }), notify: saved?.notify === true }
}

/** Only our own napplets see vault-private data. A grant's old `privateData` means nothing. */
export const seesPrivate = grant => grant?.firstParty === true

/** May this already-signed event be re-sent for a napplet (relay.publish)? Same refusals as signing: an old signed
 *  follow list, relay list or vanish request of the user's must not be replayed. -> { ok } or { ok: false, error }. */
export function resendDecision(event) {
  if (protectedKind(event?.kind)) return { ok: false, error: `kind ${event?.kind} is never sent for a napplet` }
  if (event?.kind === 5) return { ok: false, error: "napplets can't send deletions signed elsewhere" }
  return { ok: true }
}

/** Drop the events this napplet may not see: private kinds (unless granted), and anyone the user blocked. */
export function visibleEvents(events, grant, { blocked = null } = {}) {
  const priv = seesPrivate(grant)
  return events.filter(ev => ev && (priv || !PRIVATE_KINDS.has(ev.kind)) && !(blocked?.has?.(ev.pubkey)))
}

/**
 * May this napplet have this template signed? -> { ok: true, ask: boolean } or { ok: false, error }.
 * `ask`: the shell must show the user what it is about to sign before it signs.
 */
export function signDecision(grant, template) {
  const kind = template?.kind
  if (!Number.isInteger(kind) || kind < 0 || kind > 65535) return { ok: false, error: "invalid kind" }
  if (typeof template.content !== "string") return { ok: false, error: "content must be a string" }
  if (!Array.isArray(template.tags ?? []) || (template.tags ?? []).some(t => !Array.isArray(t) || t.some(v => typeof v !== "string"))) return { ok: false, error: "tags must be arrays of strings" }
  if (NEVER_SIGN.has(kind)) return { ok: false, error: `kind ${kind} is a credential; napplets can't have it signed` }
  if (ACCOUNT_KINDS.has(kind)) return { ok: false, error: `kind ${kind} is an account list; only Nostr Vault itself edits it` }
  if (kind === 5) {
    const t = deletionTargets(template)
    if (!t.count) return { ok: false, error: "a deletion must name what it deletes" }
    const bad = t.kinds.find(k => !Number.isInteger(k) || protectedKind(k))
    if (bad !== undefined) return { ok: false, error: `a napplet can't delete kind ${bad}` }
  }
  if (grant?.firstParty === true) return { ok: true, ask: false }
  if (PRIVATE_KINDS.has(kind)) return { ok: false, error: `kind ${kind} is private; only Nostr Vault's own napplets handle it` }
  return { ok: true, ask: grant?.publish !== "allow" }
}

/** Grants, kept per account in the shell's own localStorage (never the napplet's: it has none). */
export function grantStore(storage, account) {
  const KEY = `nv-napplet-grants:${account}`
  const read = () => { try { return JSON.parse(storage.getItem(KEY) || "{}") || {} } catch { return {} } }
  const write = all => storage.setItem(KEY, JSON.stringify(all))
  return {
    get: key => read()[key] ?? null,
    set: (key, grant) => { const all = read(); all[key] = grant; write(all) },
    remove: key => { const all = read(); delete all[key]; write(all) },
    list: () => read(),
  }
}
