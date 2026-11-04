// My devices, a "Your space" panel (Tod / Logen, 2026-11-04): which of the user's own devices are on the mesh, and when
// each one last was. Nostr Vault keeps no per-device sync log, so the evidence is each device's FIPS overlay advert
// (kind 37195, d "fips-overlay-v1"): the engine republishes it about every 30 minutes with a one-hour NIP-40
// expiration. The iPad's MyDevicesStatus.swift follows the same rule, against the same fixtures
// (HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MyDevices/status-cases.json). This browser has no engine
// status to share here, so "connected now" is only the iPad's. Reads only: nothing is published.
import { npubEncode } from "nostr-tools/nip19"
import { meshVaults } from "../../net/fips-ref.js"
import { pool, uniq, DEFAULT_RELAYS } from "../../net/pool.js"

export const ADVERT_KIND = 37195
export const ADVERT_D = "fips-overlay-v1"
/** An advert this far in the future is a broken clock, not a fresh one (seconds). */
export const SKEW = 600
/** An advert without a readable expiration counts for this long (seconds). */
export const FALLBACK_TTL = 3600
/** The finder relays the apps' mesh engines advertise on (MeshDevicesLogic.defaultFinderRelays). */
export const FINDER_RELAYS = ["wss://relay.nostr.net", "wss://nostr.bitcoiner.social", "wss://relay.btcforplebs.com"]
/** How often the panel looks again while it is open (ms). */
export const REFRESH_MS = 5 * 60_000

const tagOf = (ev, name) => (ev?.tags ?? []).find(t => Array.isArray(t) && t.length >= 2 && t[0] === name)?.[1]

/** { state, lastSeen } for one device: connected (its engine and ours are linked now), online (advert not expired),
 *  offline (newest advert expired), unknown (none found) or unchecked (the relays didn't answer). */
export function deviceStatus(adverts, now, { connected = false, checked = true } = {}) {
  if (connected) return { state: "connected", lastSeen: now }
  if (!checked) return { state: "unchecked", lastSeen: null }
  const ok = (adverts ?? []).filter(e => tagOf(e, "d") === ADVERT_D && Number.isInteger(e?.created_at) && e.created_at <= now + SKEW)
  if (!ok.length) return { state: "unknown", lastSeen: null }
  const newest = ok.reduce((a, b) => (b.created_at > a.created_at ? b : a))
  const raw = tagOf(newest, "expiration")
  const exp = raw != null && /^-?\d+$/.test(String(raw).trim()) ? Number(raw) : null
  const live = exp != null ? exp > now : now - newest.created_at < FALLBACK_TTL
  return { state: live ? "online" : "offline", lastSeen: newest.created_at }
}

/** "just now", "12 min ago", "3 h ago", "2 d ago". */
export function agoText(at, now) {
  const s = Math.max(0, now - at)
  if (s < 60) return "just now"
  if (s < 3600) return `${Math.floor(s / 60)} min ago`
  if (s < 86_400) return `${Math.floor(s / 3600)} h ago`
  return `${Math.floor(s / 86_400)} d ago`
}

/** Above the list: being on the mesh means your posts and media can be fetched from that device, not just that it is
 *  linked (Logen, 2026-11-04). As the iPad words it (MyDevicesStatus.header). */
export const MESH_HEADER = "Devices on your mesh share your posts and media with people who can reach them."
/** A device that is on the mesh. */
export const SHARING_LINE = "On the mesh · sharing your posts and media"

/** The row's second line, as the iPad words it. */
export function statusLine(status, now) {
  const ago = status.lastSeen != null ? agoText(status.lastSeen, now) : null
  switch (status.state) {
    case "connected": return "Connected now · sharing your posts and media"
    case "online": return SHARING_LINE
    case "offline": return ago ? `Offline · last shared ${ago}` : "Offline"
    case "unknown": return "Not seen on the mesh lately"
    default: return "Couldn't check the mesh"
  }
}

/** The user's devices this browser knows: the home vaults their newest 10063 lists (fipsmesh:// entries), then the
 *  vaults paired in Who Can Reach You. Each once, as x-only hex, with a name to show. */
export function deviceList(serverList, owners) {
  const out = []
  const seen = new Set()
  const add = (hex, role) => {
    if (!/^[0-9a-f]{64}$/.test(hex ?? "") || seen.has(hex)) return
    seen.add(hex)
    out.push({ hex, npub: npubEncode(hex), role })
  }
  for (const hex of meshVaults(serverList)) add(hex, "Home vault")
  for (const hex of owners ?? []) add(String(hex).toLowerCase(), "Paired vault")
  return out
}

/** A device's name: its role and the end of its mesh address, which is how the apps tell two of them apart. */
export const deviceName = d => `${d.role} ${d.npub.slice(0, 9)}…${d.npub.slice(-4)}`

/** -> { devices, adverts: Map<hex, event[]>, checked }. `query` is for tests. */
export async function loadMyDevices(ctx, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const me = ctx.session.pubkey
  const relays = uniq([...(ctx.account?.relays?.write ?? []), ...(ctx.account?.relays?.read ?? []), ...DEFAULT_RELAYS])
  const lists = await query(relays, { kinds: [10063], authors: [me] }, { maxWait: 5000 }).catch(() => [])
  const newest = lists.filter(e => e?.kind === 10063 && e.pubkey === me).sort((a, b) => b.created_at - a.created_at)[0]
  const devices = deviceList(newest, ctx.vault?.owners)
  if (!devices.length) return { devices, adverts: new Map(), checked: true }
  let checked = true
  const found = await query(FINDER_RELAYS, { kinds: [ADVERT_KIND], authors: devices.map(d => d.hex), "#d": [ADVERT_D], limit: 50 }, { maxWait: 6000 })
    .catch(() => { checked = false; return [] })
  const adverts = new Map(devices.map(d => [d.hex, found.filter(e => e?.kind === ADVERT_KIND && e.pubkey === d.hex)]))
  return { devices, adverts, checked }
}
