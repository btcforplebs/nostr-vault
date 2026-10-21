// Photos on a FIPS vault: which notes point at one, and the loader that reads them by hash with the photo-only reader.
import test from "node:test"
import assert from "node:assert/strict"
import { npubEncode } from "nostr-tools/nip19"
import { fipsRef, meshVaults } from "../src/net/fips-ref.js"
import { createFipsMedia, MAX_READS } from "../src/net/fips-media.js"
import { noteMedia } from "../src/net/note-media.js"

const A = "a1".repeat(32), B = "b2".repeat(32), SHA = "487dc1578912f424773b0befc4eff491f026f0f24652f1d4ff66a85639455217"
const link = (k, ext = "") => `http://${npubEncode(k)}.fips/${SHA}${ext}`
const tick = () => new Promise(r => setTimeout(r, 0))

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
  assert.deepEqual(meshVaults(ev), [B, A])
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
  const fm = createFipsMedia({ startReader, query: async () => assert.fail("a .fips link needs no 10063") })
  assert.equal(log.starts, 0, "nothing starts until a photo needs it")
  const [u1, u2] = await Promise.all([fm.fallback({ url: link(A) }), fm.fallback({ url: link(A, ".jpg") })])
  assert.match(u1, /^blob:/)
  assert.equal(u1, u2, "the same hash is read once")
  assert.equal(log.starts, 1)
  assert.deepEqual(log.gets, [A])
})

test("an https photo with a hash falls back to the author's mesh vaults from their 10063, in order", async () => {
  const { startReader, log } = fakeReader({ have: new Map([[B, new Set([SHA])]]) })
  let queries = 0
  const query = async (_r, f) => {
    queries++
    assert.deepEqual(f, { kinds: [10063], authors: [A] })
    return [
      { kind: 10063, pubkey: A, created_at: 1, tags: [["server", `fipsmesh://${npubEncode(B)}/`]] },
      { kind: 10063, pubkey: A, created_at: 2, tags: [["server", "https://x"], ["server", `fipsmesh://${npubEncode(A)}/`], ["server", `fipsmesh://${npubEncode(B)}/`]] },
      { kind: 10063, pubkey: B, created_at: 9, tags: [["server", "fipsmesh://whatever/"]] },
    ]
  }
  const fm = createFipsMedia({ startReader, query })
  const u = await fm.fallback({ url: `https://blossom.example/${SHA}.jpg`, x: SHA }, A)
  assert.match(u, /^blob:/)
  assert.deepEqual(log.gets, [A, B], "the newest list, tried in its order")
  await fm.authorVaults(A)
  assert.equal(queries, 1, "one 10063 query per author")
})

test("no mesh source: no reader, and the photo shows its fallback", async () => {
  const { startReader, log } = fakeReader()
  const fm = createFipsMedia({ startReader, query: async () => [] })
  await assert.rejects(fm.fallback({ url: "https://x/p.jpg" }, A), /no hash/)
  await assert.rejects(fm.fallback({ url: "https://x/p.jpg", x: SHA }, A), /no mesh vault/)
  await assert.rejects(fm.fallback({ url: "https://x/p.jpg", x: SHA }, "not-a-key"), /no mesh vault/)
  assert.equal(log.starts, 0)
})

test("a failed read is forgotten, so a later scroll tries again; reads are capped", async () => {
  const fail = new Set([A])
  const { startReader, log } = fakeReader({ have: new Map([[A, new Set([SHA])]]), fail })
  const fm = createFipsMedia({ startReader })
  await assert.rejects(fm.fallback({ url: link(A) }))
  fail.clear()
  assert.match(await fm.fallback({ url: link(A) }), /^blob:/)
  const many = Array.from({ length: 6 }, (_, i) => fm.photo([A], i.toString(16).padStart(64, "0")).catch(() => {}))
  await Promise.all(many)
  assert.ok(log.maxOpen <= MAX_READS, `at most ${MAX_READS} reads at once (saw ${log.maxOpen})`)
})

test("a reader that fails to start is retried on the next photo", async () => {
  let n = 0
  const fm = createFipsMedia({ startReader: async () => { if (n++ === 0) throw new Error("no seed"); return { getBlob: async () => ({ bytes: new Uint8Array(1), type: "image/png" }) } } })
  await assert.rejects(fm.fallback({ url: link(A) }), /no seed/)
  assert.match(await fm.fallback({ url: link(A) }), /^blob:/)
})

test("two notes, one hash: a read from a dead vault doesn't sink the note whose vault has it", async () => {
  const { startReader, log } = fakeReader({ have: new Map([[B, new Set([SHA])]]) })
  const fm = createFipsMedia({ startReader })
  const dead = fm.fallback({ url: link(A) })
  const live = fm.fallback({ url: link(B) })
  await assert.rejects(dead)
  assert.match(await live, /^blob:/)
  assert.deepEqual(log.gets, [A, B])
  assert.equal(await fm.fallback({ url: link(A) }), await live, "the bytes are the hash's: a later note gets them from cache")
})
