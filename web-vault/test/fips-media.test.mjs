// Photos on a FIPS vault: which notes point at one, and the loader that reads them by hash with the photo-only reader.
import test from "node:test"
import assert from "node:assert/strict"
import { npubEncode } from "nostr-tools/nip19"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { fipsRef, meshVaults } from "../src/net/fips-ref.js"
import { createFipsMedia, meshPhotosOn, setMeshPhotosOn, setMeshPeople, meshAllowed, onMeshGate, MAX_READS, MAX_VAULTS, CLOSE_MS, READ_TIMEOUT_MS, PHOTO_TIMEOUT_MS } from "../src/net/fips-media.js"
import { noteMedia } from "../src/net/note-media.js"

const A = "a1".repeat(32), B = "b2".repeat(32), SHA = "487dc1578912f424773b0befc4eff491f026f0f24652f1d4ff66a85639455217"
const link = (k, ext = "") => `http://${npubEncode(k)}.fips/${SHA}${ext}`
const tick = () => new Promise(r => setTimeout(r, 0))
// P posts the notes; a .fips link reads only from a vault P's signed 10063 lists.
const P_SK = generateSecretKey(), P = getPublicKey(P_SK)
const signedList = (vaults, created_at = 1, sk = P_SK) =>
  finalizeEvent({ kind: 10063, created_at, content: "", tags: vaults.map(v => ["server", `fipsmesh://${npubEncode(v)}/`]) }, sk)
const listing = (...vaults) => async () => [signedList(vaults)]

test("fipsRef: a NIP-F1 link names its vault and hash; anything else is not one", () => {
  assert.deepEqual(fipsRef(link(A)), { vault: A, sha256: SHA })
  assert.deepEqual(fipsRef(link(A, ".jpg")), { vault: A, sha256: SHA })
  assert.equal(fipsRef(`https://${npubEncode(A)}.fips/${SHA}`), undefined, "https is not a mesh link")
  assert.equal(fipsRef(`http://npub1qqqq.fips/${SHA}`), undefined, "not a valid npub")
  assert.equal(fipsRef(`http://${npubEncode(A)}.fips/abc`), undefined, "not a hash")
  assert.equal(fipsRef(`https://blossom.example/${SHA}.jpg`), undefined)
})

test("meshVaults: the fipsmesh:// entries of a 10063, in order, once each; https servers are not vaults", () => {
  const ev = { tags: [["server", "https://blossom.example"], ["server", `fipsmesh://${npubEncode(B)}/`], ["server", `fipsmesh://${npubEncode(A)}`], ["server", `fipsmesh://${npubEncode(B)}/`], ["server", "fipsmesh://nope/"]] }
  assert.deepEqual(meshVaults(ev), [B], "fipsmesh://<npub> without the trailing slash is not well formed (NIP-F1)")
  assert.deepEqual(meshVaults({ tags: [["server", `fipsmesh://${npubEncode(A)}/x`], ["server", `fipsmesh://${npubEncode(A)}:80/`], ["server", `fipsmesh://${npubEncode(A)}/?q`]] }), [])
  assert.deepEqual(meshVaults(undefined), [])
})

test("noteMedia: a .fips link is a photo with no extension, and imeta keeps the hash for a mesh fallback", () => {
  assert.deepEqual(noteMedia([link(A)], []), [{ url: link(A), type: "image" }])
  const url = `https://blossom.example/${SHA}.jpg`
  const [m] = noteMedia([url], [["imeta", `url ${url}`, "m image/jpeg", `x ${SHA.toUpperCase()}`, "dim 4032x3024"]])
  assert.deepEqual(m, { url, type: "image", width: 4032, height: 3024, x: SHA })
})

function fakeReader({ have = new Map(), fail = new Set() } = {}) {
  const log = { starts: 0, gets: [], open: 0, maxOpen: 0, allowedAtStart: undefined }
  const startReader = async ({ getPhotoVaults }) => {
    log.starts++
    return {
      getBlob: async (vault, sha) => {
        assert.ok(getPhotoVaults().has(vault), "the reader only ever asks a vault the note named")
        log.gets.push(vault)
        log.open++; log.maxOpen = Math.max(log.maxOpen, log.open)
        await tick(); await tick()
        log.open--
        if (fail.has(vault) || !have.get(vault)?.has(sha)) throw new Error("404")
        return { bytes: new Uint8Array([1, 2, 3]), type: "image/jpeg" }
      },
    }
  }
  return { startReader, log }
}

test("one reader for the page, started on first need; one read per hash", async () => {
  const { startReader, log } = fakeReader({ have: new Map([[A, new Set([SHA])]]) })
  const fm = createFipsMedia({ allow: () => true, startReader, query: listing(A) })
  assert.equal(log.starts, 0, "nothing starts until a photo needs it")
  const [u1, u2] = await Promise.all([fm.fallback({ url: link(A) }, P), fm.fallback({ url: link(A, ".jpg") }, P)])
  assert.match(u1, /^blob:/)
  assert.equal(u1, u2, "the same hash is read once")
  assert.equal(log.starts, 1)
  assert.deepEqual(log.gets, [A])
})

test("a .fips link dials its host only if the author's signed 10063 lists it", async () => {
  const { startReader, log } = fakeReader({ have: new Map([[A, new Set([SHA])], [B, new Set([SHA])]]) })
  const fm = createFipsMedia({ allow: () => true, startReader, query: listing(B) })
  await assert.rejects(fm.fallback({ url: link(A) }, P), /no mesh vault/, "anyone can write any npub into a link")
  await assert.rejects(fm.fallback({ url: link(A) }), /no mesh vault/, "no author, no list")
  assert.equal(log.starts, 0, "an unlisted vault is never dialled")
  assert.match(await fm.fallback({ url: link(B) }, P), /^blob:/, "the listed one is")
  assert.deepEqual(log.gets, [B])
})

test("a 10063 that fails its signature lists no vaults", async () => {
  const good = signedList([A])
  const lists = {
    tampered: { ...good, tags: [["server", `fipsmesh://${npubEncode(B)}/`]] },
    unsigned: { ...good, sig: undefined },
    flagged: { ...good, tags: [["server", `fipsmesh://${npubEncode(B)}/`]], [Symbol.for("verified")]: true },
  }
  for (const [name, ev] of Object.entries(lists)) {
    const fm = createFipsMedia({ allow: () => true, startReader: fakeReader().startReader, query: async () => [ev] })
    assert.deepEqual(await fm.authorVaults(P), [], name)
  }
  const fm = createFipsMedia({ allow: () => true, query: async () => [good] })
  assert.deepEqual(await fm.authorVaults(P), [A], "the signed list counts")
})

test("an https photo with a hash falls back to the author's mesh vaults from their 10063, in order", async () => {
  const { startReader, log } = fakeReader({ have: new Map([[B, new Set([SHA])]]) })
  let queries = 0
  const query = async (_r, f) => {
    queries++
    assert.deepEqual(f, { kinds: [10063], authors: [P] })
    return [
      signedList([B], 1),
      finalizeEvent({ kind: 10063, created_at: 2, content: "", tags: [["server", "https://x"], ["server", `fipsmesh://${npubEncode(A)}/`], ["server", `fipsmesh://${npubEncode(B)}/`]] }, P_SK),
      signedList(["c3".repeat(32)], 9, generateSecretKey()),
    ]
  }
  const fm = createFipsMedia({ allow: () => true, startReader, query })
  const u = await fm.fallback({ url: `https://blossom.example/${SHA}.jpg`, x: SHA }, P)
  assert.match(u, /^blob:/)
  assert.deepEqual(log.gets, [A, B], "the newest list, tried in its order")
  await fm.authorVaults(P)
  assert.equal(queries, 1, "one 10063 query per author")
})

test("no mesh source: no reader, and the photo shows its fallback", async () => {
  const { startReader, log } = fakeReader()
  const fm = createFipsMedia({ allow: () => true, startReader, query: async () => [] })
  await assert.rejects(fm.fallback({ url: "https://x/p.jpg" }, A), /no hash/)
  await assert.rejects(fm.fallback({ url: "https://x/p.jpg", x: SHA }, A), /no mesh vault/)
  await assert.rejects(fm.fallback({ url: "https://x/p.jpg", x: SHA }, "not-a-key"), /no mesh vault/)
  assert.equal(log.starts, 0)
})

test("a failed read is forgotten, so a later scroll tries again; reads are capped", async () => {
  const fail = new Set([A])
  const { startReader, log } = fakeReader({ have: new Map([[A, new Set([SHA])]]), fail })
  const fm = createFipsMedia({ allow: () => true, startReader, query: listing(A) })
  await assert.rejects(fm.fallback({ url: link(A) }, P))
  fail.clear()
  assert.match(await fm.fallback({ url: link(A) }, P), /^blob:/)
  const many = Array.from({ length: 6 }, (_, i) => fm.photo([A], i.toString(16).padStart(64, "0")).catch(() => {}))
  await Promise.all(many)
  assert.ok(log.maxOpen <= MAX_READS, `at most ${MAX_READS} reads at once (saw ${log.maxOpen})`)
})

test("a reader that fails to start is retried on the next photo", async () => {
  let n = 0
  const fm = createFipsMedia({ allow: () => true, query: listing(A), startReader: async () => { if (n++ === 0) throw new Error("no seed"); return { getBlob: async () => ({ bytes: new Uint8Array(1), type: "image/png" }) } } })
  await assert.rejects(fm.fallback({ url: link(A) }, P), /no seed/)
  assert.match(await fm.fallback({ url: link(A) }, P), /^blob:/)
})

test("two notes, one hash: a read from a dead vault doesn't sink the note whose vault has it", async () => {
  const { startReader, log } = fakeReader({ have: new Map([[B, new Set([SHA])]]) })
  const fm = createFipsMedia({ allow: () => true, startReader, query: listing(A, B) })
  const dead = fm.fallback({ url: link(A) }, P)
  const live = fm.fallback({ url: link(B) }, P)
  await assert.rejects(dead)
  assert.match(await live, /^blob:/)
  assert.deepEqual(log.gets, [A, B])
  assert.equal(await fm.fallback({ url: link(A) }, P), await live, "the bytes are the hash's: a later note gets them from cache")
})

// Review fixes (PR 989): no note's vault list can hold the line, a vault may answer only while asked, a photo on
// screen keeps its URL, a photo that leaves stops its read, and the reader stops when idle.
const key = i => i.toString(16).padStart(64, "0")

test("hostile vault lists can't starve an honest photo: few vaults per photo, one turn per vault", async () => {
  const dead = Array.from({ length: 30 }, (_, i) => key(i + 1))
  const dead2 = Array.from({ length: 30 }, (_, i) => key(i + 100))
  const { startReader, log } = fakeReader({ have: new Map([[B, new Set([SHA])]]) })
  const fm = createFipsMedia({ allow: () => true, startReader, query: listing(B) })
  const h1 = fm.photo(dead, key(900)).catch(() => {}), h2 = fm.photo(dead2, key(901)).catch(() => {})
  const honest = fm.fallback({ url: link(B) }, P)
  assert.match(await honest, /^blob:/)
  const before = log.gets.indexOf(B)
  assert.ok(before <= 2, `the honest vault was asked after ${before} dead reads`)
  await Promise.all([h1, h2])
  assert.equal(log.gets.length, 2 * MAX_VAULTS + 1, `each hostile photo asks only ${MAX_VAULTS} vaults`)
  assert.ok(log.maxOpen <= MAX_READS)
})

test("a photo stops trying new vaults past its own deadline", async () => {
  let now = 0
  const fm = createFipsMedia({ allow: () => true, clock: () => now, startReader: async () => ({ getBlob: async (_v, _s, { timeoutMs }) => { now += timeoutMs; throw new Error("timed out") } }) })
  const seen = []
  const fm2 = createFipsMedia({ allow: () => true, clock: () => now, startReader: async () => ({ getBlob: async (v, _s, { timeoutMs }) => { seen.push(timeoutMs); now += timeoutMs; throw new Error("timed out") } }) })
  await assert.rejects(fm.photo([A, B], SHA), /timed out/)
  await assert.rejects(fm2.photo([A, B, key(7)], SHA), /timed out/)
  assert.deepEqual(seen, [READ_TIMEOUT_MS, PHOTO_TIMEOUT_MS - READ_TIMEOUT_MS], "the third vault is never asked")
})

test("a vault may answer the page only while a read asks it", async () => {
  const during = []
  const fm = createFipsMedia({ allow: () => true, startReader: async ({ getPhotoVaults }) => ({ getBlob: async v => { during.push([...getPhotoVaults()]); await tick(); if (v === A) throw new Error("404"); return { bytes: new Uint8Array(1), type: "image/png" } } }) })
  assert.match(await fm.photo([A, B], SHA), /^blob:/)
  assert.deepEqual(during, [[A], [B]], "one vault at a time, and only the one asked")
  await assert.rejects(fm.photo([A], key(5)))
  assert.equal(fm.allowed.size, 0, "nothing stays allowed after its read")
})

test("eviction never revokes a URL a photo on screen holds; a photo that leaves lets it go", async () => {
  const revoked = new Set(), real = URL.revokeObjectURL
  URL.revokeObjectURL = u => revoked.add(u)
  try {
    const fm = createFipsMedia({ allow: () => true, startReader: async () => ({ getBlob: async () => ({ bytes: new Uint8Array(1), type: "image/png" }) }) })
    const ctls = Array.from({ length: 70 }, () => new AbortController())
    const urls = await Promise.all(ctls.map((c, i) => fm.photo([A], key(i), { signal: c.signal })))
    assert.equal(revoked.size, 0, "all 70 are on screen")
    for (const c of ctls.slice(0, 10)) c.abort()
    assert.deepEqual([...revoked].sort(), urls.slice(0, 10).sort(), "the ten that left, and only those")
    assert.equal(await fm.photo([A], key(20)), urls[20], "a kept photo is served from cache")
  } finally {
    URL.revokeObjectURL = real
  }
})

test("a photo that leaves before its turn is never read", async () => {
  const { startReader, log } = fakeReader({ have: new Map([[A, new Set([key(1), key(2), key(3)])]]) })
  const fm = createFipsMedia({ allow: () => true, startReader })
  const c = new AbortController()
  const busy = [fm.photo([A], key(1)), fm.photo([A], key(2))]
  const gone = fm.photo([B], key(3), { signal: c.signal })
  c.abort()
  await assert.rejects(gone, e => e.name === "AbortError")
  await Promise.all(busy)
  await tick(); await tick()
  assert.ok(!log.gets.includes(B), "the vault of the photo that left was never asked")
})

test("the reader stops once no photo needs it, and starts again for the next", async () => {
  const timers = [], stops = []
  let starts = 0
  const fm = createFipsMedia({ allow: () => true,
    setTimer: fn => (timers.push(fn), timers.length), clearTimer: () => {},
    startReader: async () => { const n = ++starts; return { stop: async () => stops.push(n), getBlob: async () => ({ bytes: new Uint8Array(1), type: "image/png" }) } },
  })
  await fm.photo([A], key(1))
  assert.equal(timers.length, 1, "idle: a stop is due")
  timers[0](); await tick()
  assert.deepEqual(stops, [1])
  await fm.photo([A], key(2))
  assert.equal(starts, 2, "a new reader (and a new throwaway key) for the next photo")
})

test("the Settings switch: FIPS photos are on until the person turns them off", () => {
  const m = new Map(), st = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: k => m.delete(k) }
  assert.equal(meshPhotosOn(st), true, "on by default")
  setMeshPhotosOn(false, st)
  assert.equal(meshPhotosOn(st), false)
  setMeshPhotosOn(true, st)
  assert.equal(meshPhotosOn(st), true)
})

test("only notes from you or people you follow use the mesh, and none with the switch off", async () => {
  const friendSk = generateSecretKey()
  const me = key(500), friend = getPublicKey(friendSk), stranger = key(502)
  setMeshPeople(me, [friend])
  assert.equal(meshAllowed(me, true), true, "your own")
  assert.equal(meshAllowed(friend, true), true, "a follow")
  assert.equal(meshAllowed(stranger, true), false, "a stranger")
  assert.equal(meshAllowed(undefined, true), false, "no author")
  assert.equal(meshAllowed(friend, false), false, "switch off")
  setMeshPeople(me, [friend, stranger])
  assert.equal(meshAllowed(stranger, true), true, "a new follow counts at once")

  let started = 0, queried = 0
  const fm = createFipsMedia({ allow: a => a === friend, query: async () => (queried++, [signedList([A], 1, friendSk)]), startReader: async () => (started++, { getBlob: async () => ({ bytes: new Uint8Array(1), type: "image/png" }) }) })
  await assert.rejects(fm.fallback({ url: link(A) }, stranger), /not from someone you follow/)
  await assert.rejects(fm.fallback({ url: `https://x/${SHA}.jpg`, x: SHA }, stranger), /not from someone you follow/)
  assert.equal(started + queried, 0, "a stranger's note starts no reader and reads no 10063")
  assert.match(await fm.fallback({ url: link(A) }, friend), /^blob:/)
  setMeshPeople(undefined, [])
})

test("a photo that leaves mid-read gives its slot back at once, not at its timeout", async () => {
  const asked = []
  const fm = createFipsMedia({ allow: () => true, startReader: async () => ({
    getBlob: (v, sha, { signal }) => {
      asked.push(sha)
      if (sha === key(3)) return Promise.resolve({ bytes: new Uint8Array(1), type: "image/png" })
      return new Promise((_, no) => signal.addEventListener("abort", () => no(Object.assign(new Error("reset"), { name: "AbortError" }))))
    },
  }) })
  const ctls = [new AbortController(), new AbortController()]
  const slow = ctls.map((c, i) => fm.photo([A], key(i + 1), { signal: c.signal }))
  await tick(); await tick()
  assert.equal(asked.length, MAX_READS, "both slots taken by slow vaults")
  const honest = fm.photo([B], key(3))
  await tick(); await tick()
  assert.equal(asked.length, MAX_READS, "the next photo waits its turn")
  for (const c of ctls) c.abort()
  assert.match(await honest, /^blob:/, "and gets a slot as soon as they leave")
  await Promise.allSettled(slow)
})

test("after a good read the vault stays allowed until its stream has closed", async () => {
  let close
  const fm = createFipsMedia({ allow: () => true, startReader: async () => ({
    getBlob: async () => ({ bytes: new Uint8Array(1), type: "image/png", closed: new Promise(r => { close = r }) }),
  }) })
  assert.match(await fm.photo([A], SHA), /^blob:/)
  assert.deepEqual([...fm.allowed], [A], "its ACK/FIN can still get in")
  close(); await tick()
  assert.equal(fm.allowed.size, 0, "and not after")
})

test("the gate tells mounted photos when it changes, and only when it does", () => {
  let n = 0
  const off = onMeshGate(() => n++)
  try {
    setMeshPeople("c3".repeat(32), [A])
    const base = n
    setMeshPeople("c3".repeat(32), [A]) // a new array, same people
    assert.equal(n, base, "same people: no change")
    setMeshPeople("c3".repeat(32), [A, B])
    assert.equal(n, base + 1, "a new follow")
    const m = new Map(), st = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: k => m.delete(k) }
    setMeshPhotosOn(false, st)
    assert.equal(n, base + 2, "the switch")
  } finally { off(); setMeshPeople(undefined, []) }
})

test("a close that never settles still lets the vault go after CLOSE_MS", async () => {
  const timers = []
  const fm = createFipsMedia({ allow: () => true, setTimer: (fn, ms) => (timers.push({ fn, ms }), timers.length), clearTimer: () => {},
    startReader: async () => ({ getBlob: async () => ({ bytes: new Uint8Array(1), type: "image/png", closed: new Promise(() => {}) }) }) })
  assert.match(await fm.photo([A], SHA), /^blob:/)
  assert.deepEqual([...fm.allowed], [A])
  const cap = timers.find(t => t.ms === CLOSE_MS)
  assert.ok(cap, "a cap is set")
  cap.fn()
  assert.equal(fm.allowed.size, 0)
})
