// The relay half of the public post page: the post, its replies and the profiles to name them, from public relays.
// Every event is signature-checked before it is drawn. `query(relays, filter)` is injectable for tests.
import { verifiedCopy } from "../src/net/thread.js"
import { mentionedPubkeys, meshPhotoAuthors, meshVaults, profileOf } from "./page.js"

/** Where to look, after the link's own relay hints. */
export const READ_RELAYS = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://relay.btcforplebs.com", "wss://relay.snort.social"]
export const PROFILE_RELAYS = ["wss://purplepag.es", "wss://relay.primal.net", "wss://relay.damus.io"]
const MAX_HINTS = 3
const REPLY_LIMIT = 300

/** A link's relay hint, if it is one the server may dial: wss:// to a public host name. The server reaches out to
 *  these, so an IP literal, localhost or a single-label name (anything on the server's own network) is refused. */
export function safeRelay(url) {
  let u
  try { u = new URL(String(url).trim()) } catch { return null }
  if (u.protocol !== "wss:" || u.username || u.password) return null
  const host = u.hostname.toLowerCase()
  if (!host.includes(".") || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) return null
  if (/^[\d.]+$/.test(host) || host.startsWith("[")) return null
  return u.href.replace(/\/$/, "")
}

export function relaysFor(target) {
  const hints = (target.relays ?? []).map(safeRelay).filter(Boolean).slice(0, MAX_HINTS)
  return [...new Set([...hints, ...READ_RELAYS])]
}

const verified = evs => {
  const byId = new Map()
  for (const ev of evs) { const v = verifiedCopy(ev); if (v && !byId.has(v.id)) byId.set(v.id, v) }
  return [...byId.values()]
}

/** The mesh vaults each author's newest signed 10063 names (fipsmesh://), for the photos the page puts on the mesh.
 *  -> Map<pubkey, [x-only hex]>, only authors that name one. */
export async function readMeshVaults(pubkeys, query, relays = READ_RELAYS) {
  const out = new Map()
  const want = [...new Set(pubkeys)].slice(0, 100)
  if (!want.length) return out
  const lists = verified(await query(relays, { kinds: [10063], authors: want }))
    .filter(ev => ev.kind === 10063 && want.includes(ev.pubkey))
    .sort((a, b) => a.created_at - b.created_at) // newest wins
  const newest = new Map(lists.map(ev => [ev.pubkey, ev]))
  for (const [pk, ev] of newest) { const vs = meshVaults(ev); if (vs.length) out.set(pk, vs) }
  return out
}

/** Whether `post`'s author signed a deletion (kind 5) of it, by id or, for an addressable post, by address. */
export async function readDeleted(post, query, relays = READ_RELAYS) {
  const d = post.kind >= 30000 && post.kind < 40000 ? post.tags.find(t => t[0] === "d")?.[1] : null
  const address = typeof d === "string" ? `${post.kind}:${post.pubkey}:${d}` : null
  const filters = [{ kinds: [5], authors: [post.pubkey], "#e": [post.id] }, ...(address ? [{ kinds: [5], authors: [post.pubkey], "#a": [address] }] : [])]
  const found = verified((await Promise.all(filters.map(f => query(relays, f)))).flat())
  return found.some(ev => ev.kind === 5 && ev.pubkey === post.pubkey &&
    ev.tags.some(t => (t[0] === "e" && t[1] === post.id) || (address && t[0] === "a" && t[1] === address && ev.created_at >= post.created_at)))
}

/** -> { post, events (replies), profiles: Map<pubkey, { name, picture, nip05 }>, vaults: [hex], replyVaults: Map<pubkey,
 *  [hex]> }, post null when no relay had it. `vaults`: the mesh vaults the post author's 10063 names (readMeshVaults),
 *  only when the post has a hashed photo and its author hasn't deleted it (readDeleted). `replyVaults`: the vaults each
 *  reply author with a hashed photo names, for a fallback read only when that photo's https link fails.
 *  Reads run side by side where they can (the post with its replies), since a chat app's unfurler waits seconds. */
export async function loadThread(target, query) {
  const relays = relaysFor(target)
  const address = target.id ? null : `${target.kind}:${target.author}:${target.identifier}`
  const replyFilters = address
    ? [{ kinds: [1, 1111], "#a": [address], limit: REPLY_LIMIT }, { kinds: [1111], "#A": [address], limit: REPLY_LIMIT }]
    : [{ kinds: [1], "#e": [target.id], limit: REPLY_LIMIT }]
  const [postEvents, ...replySets] = await Promise.all([
    query(relays, address ? { kinds: [target.kind], authors: [target.author], "#d": [target.identifier], limit: 5 } : { ids: [target.id] }),
    ...replyFilters.map(f => query(relays, f)),
  ])
  const found = verified(postEvents)
    .filter(ev => (address ? ev.kind === target.kind && ev.pubkey === target.author && ev.tags.some(t => t[0] === "d" && t[1] === target.identifier) : ev.id === target.id))
  const post = found.sort((a, b) => b.created_at - a.created_at)[0] ?? null
  if (!post) return { post: null, events: [], profiles: new Map(), vaults: [], replyVaults: new Map() }
  let events = verified(replySets.flat())

  const peopleOf = evs => evs.flatMap(e => [e.pubkey, ...mentionedPubkeys(e.content)])
  const profiles = new Map()
  const readProfiles = async pubkeys => {
    const want = [...new Set(pubkeys)].filter(pk => !profiles.has(pk)).slice(0, 200)
    if (!want.length) return
    const kind0s = verified(await query(PROFILE_RELAYS, { kinds: [0], authors: want }))
    for (const ev of kind0s.sort((a, b) => a.created_at - b.created_at)) profiles.set(ev.pubkey, profileOf(ev)) // newest wins
  }

  // Deep replies that tag only their parent (old positional tags) take one more hop, beside the profile read.
  const deeper = !address && events.length
    ? query(relays, { kinds: [1], "#e": events.map(e => e.id).slice(0, 100), limit: REPLY_LIMIT })
    : Promise.resolve([])
  // One 10063 read for the post's author and every reply author with a hashed photo.
  const meshAuthors = meshPhotoAuthors([post, ...events])
  const postMesh = meshPhotoAuthors([post]).length > 0
  const read = Promise.all([readMeshVaults(meshAuthors, query, relays), postMesh ? readDeleted(post, query, relays) : false])
  const [more, , [byAuthor, deleted]] = await Promise.all([deeper, readProfiles(peopleOf([post, ...events])), read])
  const have = new Set(events.map(e => e.id))
  const extra = verified(more).filter(e => !have.has(e.id))
  if (extra.length) {
    events = [...events, ...extra]
    const asked = new Set(meshAuthors)
    const [, late] = await Promise.all([readProfiles(peopleOf(extra)), readMeshVaults(meshPhotoAuthors(extra).filter(pk => !asked.has(pk)), query, relays)])
    for (const [pk, vs] of late) byAuthor.set(pk, vs)
  }
  const vaults = postMesh && !deleted ? byAuthor.get(post.pubkey) ?? [] : []
  const replyVaults = new Map([...byAuthor].filter(([pk]) => events.some(e => e.pubkey === pk)))
  return { post, events, profiles, vaults, replyVaults }
}
