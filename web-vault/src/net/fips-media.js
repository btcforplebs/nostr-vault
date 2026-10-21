// Note photos that live on a FIPS vault, loaded like any other image: a NIP-F1 link `http://<npub>.fips/<sha256>`,
// or an https photo whose server can't serve it while the author's 10063 lists a `fipsmesh://<npub>/` vault and the
// imeta gives its hash (x). The first such photo starts web-relay's photo-only reader in the background: a fresh key,
// never saved, the public seeds only, no relay, nothing published. Each photo is read by hash and checked against
// it (blob-get.js), then shown from a blob: URL. One read per hash, a few at a time.
import { fipsRef, meshVaults } from "./fips-ref.js"
import { pool, DEFAULT_RELAYS, PROFILE_RELAYS, BROADCAST_RELAYS, uniq } from "./pool.js"

const SHA256 = /^[0-9a-f]{64}$/
/** Reads at once, across every vault: each is a TCP stream over the seeds, and the blob node caps its readers. */
export const MAX_READS = 2
/** How long one photo may take, start to bytes, before its fallback shows. */
export const READ_TIMEOUT_MS = 45_000
/** Photos kept as blob: URLs; past this the oldest is released. */
const MAX_KEPT = 60

/**
 * The loader. `startReader` is web-relay's startPhotoReader (tests pass a fake); `query` reads a 10063.
 * The reader may only ask the vaults a note named, so a photo never goes anywhere a note didn't point.
 */
export function createFipsMedia({ startReader = defaultReader, query = (r, f, o) => pool.querySync(r, f, o), relays = uniq([...DEFAULT_RELAYS, ...BROADCAST_RELAYS, ...PROFILE_RELAYS]) } = {}) {
  const allowed = new Set()
  const photos = new Map() // sha256 -> { p: Promise<blob: url>, vs: the vaults it asks }
  const lists = new Map() // author -> Promise<vaults>
  let reader, running = 0
  const waiting = []

  const getReader = () => (reader ??= startReader({ getPhotoVaults: () => allowed }).catch(e => { reader = undefined; throw e }))
  const slot = async () => {
    if (running >= MAX_READS) await new Promise(r => waiting.push(r))
    running++
  }
  const release = () => { running--; waiting.shift()?.() }

  async function read(vaults, sha256) {
    for (const v of vaults) allowed.add(v)
    const r = await getReader()
    await slot()
    try {
      let last
      for (const vault of vaults) {
        try {
          const { bytes, type } = await r.getBlob(vault, sha256, { timeoutMs: READ_TIMEOUT_MS })
          return URL.createObjectURL(new Blob([bytes], { type }))
        } catch (e) {
          last = e
        }
      }
      throw last ?? new Error("no vault")
    } finally {
      release()
    }
  }

  /** A blob: URL for this hash from the first of `vaults` that has it. Rejects when none can be reached. */
  function photo(vaults, sha256) {
    const sha = String(sha256 ?? "").toLowerCase()
    const vs = uniq((vaults ?? []).filter(v => /^[0-9a-f]{64}$/.test(v)))
    if (!SHA256.test(sha) || !vs.length) return Promise.reject(new Error("not a mesh photo"))
    const have = photos.get(sha)
    // Same hash, same bytes: a read already under way serves this photo too. If it fails, a note naming a vault it
    // didn't try still gets its own read (the failed one has left the cache by then: its catch was added first).
    if (have) return have.p.catch(e => { if (vs.every(v => have.vs.includes(v))) throw e; return photo(vs, sha) })
    const p = read(vs, sha)
    p.catch(() => { if (photos.get(sha)?.p === p) photos.delete(sha) }) // a later scroll may find the vault up
    photos.set(sha, { p, vs })
    if (photos.size > MAX_KEPT) {
      const [oldest, op] = photos.entries().next().value
      photos.delete(oldest)
      op.p.then(u => URL.revokeObjectURL(u), () => {})
    }
    return p
  }

  /** The author's mesh vaults from their newest 10063; [] when they list none. One query per author. */
  function authorVaults(pubkey) {
    if (!/^[0-9a-f]{64}$/.test(String(pubkey ?? ""))) return Promise.resolve([])
    let p = lists.get(pubkey)
    if (!p) {
      p = query(relays, { kinds: [10063], authors: [pubkey] }, { maxWait: 4000 })
        .then(evs => meshVaults((evs ?? []).filter(e => e?.kind === 10063 && e.pubkey === pubkey).sort((a, b) => b.created_at - a.created_at)[0]))
        .catch(() => [])
      lists.set(pubkey, p)
    }
    return p
  }

  /** A media item's image from the mesh: its .fips link, else (after its https url failed) its imeta hash on the
   *  author's mesh vaults. Rejects when it has no mesh source or none answers. */
  async function fallback(item, author) {
    const ref = fipsRef(item.url)
    if (ref) return photo([ref.vault], ref.sha256)
    if (!item.x) throw new Error("no hash")
    const vaults = await authorVaults(author)
    if (!vaults.length) throw new Error("no mesh vault")
    return photo(vaults, item.x)
  }

  return { photo, authorVaults, fallback, allowed }
}

async function defaultReader(opts) {
  const { startPhotoReader } = await import("../../../web-relay/src/fips/photo-reader.js")
  return startPhotoReader(opts)
}

let shared
/** The page's one loader (one reader, one cache). */
export const fipsMedia = () => (shared ??= createFipsMedia())
