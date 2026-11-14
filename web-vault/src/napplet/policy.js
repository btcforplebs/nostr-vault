// What a napplet may see and sign. Pure, so node tests load it. Logen's decision 2 (RESEARCH/NV_WEB_NAPPLET_PLAN.md
// §8): an outside napplet sees vault-private data only when the user authorizes it, per napplet. Our own napplets
// (first-party, built into this app, matched by artifact hash) are trusted like the screens they replace.
//
// "Vault-private" here is:
//   - anything read out of the in-page Haven (the vault: the user's cache of their feed, inbox and own events);
//   - private kinds wherever they come from: DMs and gift wraps, the DM relay list, app data, mute lists, wallet;
//   - the user's mute and block lists (identity.getMutes / getBlocked);
//   - the vault's own files (resource from the vault or the mesh).
// Without the grant an outside napplet reads the network only, through the shell's pool, with private kinds removed.
// The shell's block list (the WoT side, decision 6) applies to every napplet, granted or not.

/** Kinds no outside napplet sees without the private-data grant, even from a public relay. */
export const PRIVATE_KINDS = new Set([
  4, 13, 14, 15, 1059, 1060, // DMs, seals, gift wraps (NIP-04, NIP-17, NIP-59)
  10000, 10050, 30078, // mute list, DM relays, app data
  7374, 7375, 7376, 17375, 37375, 13194, 23194, 23195, // wallet: cashu (NIP-60) and NWC (NIP-47)
])

/** Kinds no napplet may have signed, ours included: one bad list wipes the account's follows or relays. Lists are
 *  edited only by the app's own guarded editors (test/user-list-sign-guard.test.mjs); a napplet asks the shell. */
export const ACCOUNT_KINDS = new Set([0, 3, 10000, 10002, 10006, 10050, 10063])

/** Kinds no napplet ever gets signed, ours included: each is a credential (relay AUTH, Blossom auth, HTTP auth, NWC). */
export const NEVER_SIGN = new Set([22242, 24242, 27235, 13194, 23194, 23195])

/** A napplet's grant: what the user said yes to. First-party napplets get everything they ask for. */
export function defaultGrant({ firstParty = false, domains = [] } = {}) {
  return { firstParty, domains: [...domains], privateData: firstParty, publish: firstParty ? "allow" : "ask", notify: firstParty }
}

export const seesPrivate = grant => !!(grant?.firstParty || grant?.privateData)

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
  if (grant?.firstParty) return { ok: true, ask: false }
  if (PRIVATE_KINDS.has(kind) && !grant?.privateData) return { ok: false, error: `kind ${kind} is private; this napplet has no private-data grant` }
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
