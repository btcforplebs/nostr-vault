// Several desktop Vaults in the public lists (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.5, rules 1-6), the web twin of Apple
// Models/DesktopVaultsLists.swift and Android relay/DesktopVaultsRules. Pure: a list's tags as fetched in, the tags to
// sign out, so a caller only ever applies one Vault's change to the newest list (rule 7). Shared fixtures:
// docs/fixtures/desktop-vaults/lists.json (test/box-desktop-vault-lists.test.mjs). Box › Public on the web
// (public-on-web.js) uses it with the box as the one Vault it knows.
//
// A Vault is `{ id, name, kind, meshNpub?, httpsURL?, order }` (§2.1). A list is its kind number: 10002 relays
// (`["r", "wss://host"]` and `["fipsmesh", "fipsmesh://<npub>/", "write"]`), 10050 DM inbox (`["relay", …]`, no mesh
// entry), 10063 media servers (`["server", "https://host"]` and `["server", "fipsmesh://<npub>/"]`).

export const LISTS = [10002, 10050, 10063]
const ENTRY = { 10002: "r", 10050: "relay", 10063: "server" }
const SCHEMES = ["wss://", "ws://", "https://", "http://"]

/** The message a refused change shows (rule 5). */
export const refusal = list => ({ 10002: "Add another relay first.", 10050: "Add another DM inbox relay first.", 10063: "Add another media server first." })[list]
export const overGuidanceNote = "Other apps may only use the first few."

// ---- rule 1: which entries are a Vault's ----

/** One spelling per web host: scheme, case, path, trailing slash and a default port fold away. null for a mesh
 *  address or anything with no host. */
export function hostKey(raw) {
  let text = String(raw ?? "").trim().toLowerCase()
  if (text.startsWith("fipsmesh:")) return null
  for (const s of SCHEMES) if (text.startsWith(s)) { text = text.slice(s.length); break }
  const cut = text.search(/[/?#]/)
  if (cut >= 0) text = text.slice(0, cut)
  for (const p of [":443", ":80"]) if (text.endsWith(p)) text = text.slice(0, -p.length)
  return !text || text.includes(" ") ? null : text
}

/** The Vault's whole base, scheme and trailing slashes off (DesktopVaultsLogic.base). */
export function base(raw) {
  let url = String(raw ?? "").trim()
  for (const s of SCHEMES) if (url.toLowerCase().startsWith(s)) { url = url.slice(s.length); break }
  return url.replace(/\/+$/, "")
}

/** The npub of a mesh address in any spelling the apps take (HomeVaultLogic.meshNpub), or null. */
export function meshNpubOf(input) {
  let text = String(input ?? "").trim()
  if (text.toLowerCase().startsWith("nostr:")) text = text.slice(6)
  if (!text.startsWith("fipsmesh://")) text = `fipsmesh://${text}/`
  if (!text.endsWith("/")) text += "/"
  const m = /^fipsmesh:\/\/(npub1[02-9ac-hj-np-z]{58})\/(\?.*)?$/i.exec(text)
  return m ? m[1].toLowerCase() : null
}

/** The npub of a mesh entry (a 10002 `fipsmesh` tag or a 10063 mesh `server`), null for any other tag. */
export function meshNpub(tag, list) {
  if (!Array.isArray(tag) || tag.length < 2) return null
  if (!((list === 10002 && tag[0] === "fipsmesh") || (list === 10063 && tag[0] === "server"))) return null
  if (!String(tag[1]).toLowerCase().startsWith("fipsmesh:")) return null
  return meshNpubOf(String(tag[1]).toLowerCase())
}

/** The host of a web entry, null for a mesh entry or any other tag. */
export function webHost(tag, list) {
  if (!Array.isArray(tag) || tag.length < 2 || tag[0] !== ENTRY[list]) return null
  return hostKey(tag[1])
}

const vaultHost = v => (v.httpsURL ? hostKey(v.httpsURL) : null)
const vaultMesh = v => (v.meshNpub ? meshNpubOf(v.meshNpub) : null)

/** The Vault an entry belongs to, or null: every other entry is the user's own and no Vault switch touches it. */
export function owner(tag, list, vaults) {
  const npub = meshNpub(tag, list)
  if (npub) return vaults.find(v => vaultMesh(v) === npub) ?? null
  const host = webHost(tag, list)
  if (host) return vaults.find(v => vaultHost(v) === host) ?? null
  return null
}

export function isEntry(tag, vault, path, list) {
  if (path === "web") {
    const host = vaultHost(vault)
    return !!host && webHost(tag, list) === host
  }
  const npub = vaultMesh(vault)
  return !!npub && meshNpub(tag, list) === npub
}

export const isListed = (vault, path, list, tags) => (tags ?? []).some(t => isEntry(t, vault, path, list))

/** The entry a switch adds, or null when the Vault has no such address or the list takes none (10050 has no mesh). */
export function entry(vault, path, list) {
  if (path === "web") {
    if (!vault.httpsURL || !vaultHost(vault)) return null
    const b = base(vault.httpsURL)
    return { 10002: ["r", `wss://${b}`], 10050: ["relay", `wss://${b}/inbox`], 10063: ["server", `https://${b}`] }[list]
  }
  const npub = vaultMesh(vault)
  if (!npub) return null
  return { 10002: ["fipsmesh", `fipsmesh://${npub}/`, "write"], 10050: null, 10063: ["server", `fipsmesh://${npub}/`] }[list]
}

// ---- rule 2: order ----

const before = (a, b) => a.order < b.order || (a.order === b.order && a.id < b.id)

/** Turns a Vault's switch on: `{ tags }` or `{ refused: list }`. Its entry goes after the other Vault entries of the
 *  same path, in Desktop Vaults order, before the user's own; mesh entries always last. Nothing else moves. */
export function turningOn(vault, path, list, tags, vaults) {
  const e = entry(vault, path, list)
  if (!e || isListed(vault, path, list, tags)) return { tags }
  const isMesh = t => meshNpub(t, list) != null
  const firstMeshAt = tags.findIndex(isMesh)
  const firstMesh = firstMeshAt < 0 ? tags.length : firstMeshAt
  const placed = []
  tags.forEach((t, i) => {
    if (isMesh(t) !== (path === "mesh")) return
    const other = owner(t, list, vaults)
    if (other && other.id !== vault.id) placed.push({ index: i, vault: other })
  })
  let index
  const later = placed.find(p => before(vault, p.vault))
  if (later) index = later.index
  else if (placed.length) index = placed[placed.length - 1].index + 1
  else index = path === "mesh" ? tags.length : 0
  if (path === "web") index = Math.min(index, firstMesh)
  const out = [...tags.slice(0, index), e, ...tags.slice(index)]
  if (path === "mesh" && !isUsable(out, list)) return { refused: list }
  return { tags: out }
}

/** The tags with the Vault entries in Desktop Vaults order, in the places Vault entries already hold. */
export function reordered(tags, list, vaults) {
  const out = [...tags]
  for (const mesh of [false, true]) {
    const slots = []
    tags.forEach((t, i) => { if ((meshNpub(t, list) != null) === mesh && owner(t, list, vaults)) slots.push(i) })
    const sorted = slots.map((i, offset) => ({ tag: tags[i], offset })).sort((a, b) => {
      const va = owner(a.tag, list, vaults), vb = owner(b.tag, list, vaults)
      if (va.id === vb.id) return a.offset - b.offset
      return before(va, vb) ? -1 : 1
    })
    slots.forEach((slot, i) => { out[slot] = sorted[i].tag })
  }
  return out
}

// ---- rule 5: removal ----

/** Whether a list may be signed: 10002 keeps a wss write relay (a mesh relay doesn't count), 10050 a relay, 10063 an
 *  https server. */
export function isUsable(tags, list) {
  const ok = t => Array.isArray(t) && t.length >= 2
  if (list === 10002) return tags.some(t => ok(t) && t[0] === "r" && String(t[1]).toLowerCase().startsWith("wss://") && (t.length < 3 || t[2] !== "read"))
  if (list === 10050) return tags.some(t => ok(t) && t[0] === "relay" && hostKey(t[1]) != null)
  return tags.some(t => ok(t) && t[0] === "server" && String(t[1]).toLowerCase().startsWith("https://"))
}

/** Turns a Vault's switch off: its entries of `path` out in every spelling, nothing else. A list left unusable is
 *  `{ refused }` (mesh entries may always come off). */
export function turningOff(vault, path, list, tags) {
  const out = tags.filter(t => !isEntry(t, vault, path, list))
  if (out.length === tags.length) return { tags }
  if (path === "web" && !isUsable(out, list)) return { refused: list }
  return { tags: out }
}

/** Deleting a Vault and taking it out of its public lists: `{ changed: { [list]: tags } }` for the lists that change,
 *  or `{ refused: list }` with nothing to sign when any one would be left unusable. `lists`: `{ [list]: tags }`. */
export function removingVault(vault, lists) {
  const changed = {}
  for (const list of LISTS) {
    const tags = lists[list]
    if (!tags) continue
    let current = tags
    for (const path of ["mesh", "web"]) {
      const r = turningOff(vault, path, list, current)
      if (r.refused) return { refused: r.refused }
      current = r.tags
    }
    if (current !== tags) changed[list] = current
  }
  return { changed }
}

// ---- rule 4: one host, one Vault ----

/** The other Vault that already has this address's host, or null. */
export function hostTaken(httpsURL, vaults, exceptId = null) {
  const host = hostKey(httpsURL)
  return host ? vaults.find(v => v.id !== exceptId && vaultHost(v) === host) ?? null : null
}

export const displayName = v => (v.name ?? "").trim() || vaultHost(v) || (v.meshNpub ? `${v.meshNpub.slice(0, 12)}…` : "Desktop Vault")
export const hostTakenMessage = v => `That address is already your Vault ${displayName(v)}.`

// ---- rule 6: size ----

/** More entries than other apps are told to use (NIP-65: 4 write relays, mesh relays not counted; NIP-17: 3). */
export function overGuidance(tags, list) {
  const ok = t => Array.isArray(t) && t.length >= 2
  if (list === 10002) return tags.filter(t => ok(t) && t[0] === "r" && hostKey(t[1]) != null && (t.length < 3 || t[2] !== "read")).length > 4
  if (list === 10050) return tags.filter(t => ok(t) && t[0] === "relay").length > 3
  return false
}
