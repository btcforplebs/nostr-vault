// Vault › Media: server lists merged by hash, a server that wants authorisation asked again with one signed "list"
// auth, delete and mirror scoped to the file's hash, and the kinds and day groups the grid shows. Throwaway keys and
// a fake fetch: no server is contacted.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { listBlobs, deleteBlob, mirrorBlob, mediaType, byDay, outcome, blossomAuthTemplate, TYPE_FILTERS } from "../src/net/blossom-gallery.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const signs = []
const ctx = { session: { pubkey: ME }, signer: { signEvent: async t => { signs.push(t); return finalizeEvent(t, SK) } } }
const H = c => c.repeat(64)
const A = "https://a.example", B = "https://b.example", C = "https://c.example", D = "https://d.example"
const res = (status, body, reason) => ({ ok: status >= 200 && status < 300, status, json: async () => body, headers: { get: k => k === "X-Reason" ? reason : null } })
const authOf = h => JSON.parse(atob(h.replace(/^Nostr /, "")))

test("lists merge by hash with the servers that hold each, newest first; bad entries and servers are reported", async () => {
  signs.length = 0
  const calls = []
  const fetch = async (url, opt = {}) => {
    calls.push([url, opt.headers?.Authorization ? "auth" : "none"])
    if (url.startsWith(A)) return res(200, [{ sha256: H("1"), url: `${A}/${H("1")}.jpg`, type: "image/jpeg", size: 10, uploaded: 100 }, { sha256: "nothex", url: "x" }])
    if (url.startsWith(B)) return opt.headers?.Authorization ? res(200, [{ sha256: H("1"), url: `${B}/${H("1")}.jpg`, uploaded: 100 }, { sha256: H("2"), url: `${B}/${H("2")}.mp4`, uploaded: 300 }]) : res(400, null, "missing auth event")
    // A refusal without CORS headers: the page sees only a failed fetch.
    if (url.startsWith(D)) { if (!opt.headers?.Authorization) throw new TypeError("Failed to fetch"); return res(200, [{ sha256: H("3"), url: `${D}/${H("3")}.gif`, uploaded: 200 }]) }
    return res(500, null, "boom")
  }
  const { blobs, status } = await listBlobs([A, B, C, D], ME, { ctx, fetch })
  assert.deepEqual(blobs.map(b => [b.sha256[0], b.kind, b.servers]), [["2", "video", [B]], ["3", "gif", [D]], ["1", "photo", [A, B]]])
  assert.equal(blobs[2].url, `${A}/${H("1")}.jpg`, "the first server's URL")
  assert.deepEqual(status, { [A]: "ok", [B]: "ok", [C]: "boom", [D]: "ok" })
  assert.equal(calls.filter(c => c[0] === `${A}/list/${ME}`).length, 1)
  assert.deepEqual(calls.filter(c => c[0].startsWith(B)).map(c => c[1]), ["none", "auth"])
  assert.equal(signs.length, 1, "one list auth, only because a server asked")
  assert.deepEqual(signs[0].tags.filter(t => t[0] !== "expiration"), [["t", "list"]])
  // Opening Media again within the auth's life doesn't ask the signer again.
  await listBlobs([B], ME, { ctx, fetch })
  assert.equal(signs.length, 1)
})

test("a read-only account isn't asked to sign; the server just shows as refusing", async () => {
  signs.length = 0
  const { status } = await listBlobs([A, B], ME, { ctx: { ...ctx, signer: { readOnly: true } }, fetch: async url => { if (url.startsWith(B)) throw new TypeError("Failed to fetch"); return res(401, null, "auth required") } })
  assert.deepEqual(status, { [A]: "auth required", [B]: "Failed to fetch" })
  assert.equal(signs.length, 0)
})

test("delete goes to every server holding the file with a delete auth for its hash; 404 counts as gone", async () => {
  const seen = []
  const blob = { sha256: H("a"), url: `${A}/${H("a")}`, servers: [A, B] }
  const r = await deleteBlob(blob, { ctx, fetch: async (url, opt) => { seen.push([url, opt.method, authOf(opt.headers.Authorization)]); return url.startsWith(A) ? res(200) : res(404) } })
  assert.deepEqual(seen.map(s => [s[0], s[1]]), [[`${A}/${H("a")}`, "DELETE"], [`${B}/${H("a")}`, "DELETE"]])
  const auth = seen[0][2]
  assert.ok(verifyEvent(auth) && auth.kind === 24242 && auth.pubkey === ME)
  assert.deepEqual(auth.tags.slice(0, 2), [["t", "delete"], ["x", H("a")]])
  assert.ok(r.every(x => x.ok))
})

test("mirror asks only the servers missing the file, and counts a copy only when the hash comes back", async () => {
  const blob = { sha256: H("b"), url: `${A}/${H("b")}`, servers: [A] }
  const asked = []
  const r = await mirrorBlob(blob, [A, B, C], { ctx, fetch: async (url, opt) => { asked.push(url); assert.deepEqual(JSON.parse(opt.body), { url: blob.url }); assert.deepEqual(authOf(opt.headers.Authorization).tags.slice(0, 2), [["t", "upload"], ["x", H("b")]]); return url.startsWith(B) ? res(200, { sha256: H("b") }) : res(200, { sha256: H("c") }) } })
  assert.deepEqual(asked, [`${B}/mirror`, `${C}/mirror`])
  assert.deepEqual(r.map(x => [x.server, x.ok]), [[B, true], [C, false]])
  assert.match(outcome(r, "Copied"), /^Copied on 1 of 2 servers\. c\.example: didn't confirm/)
  assert.deepEqual(await mirrorBlob({ ...blob, servers: [A, B] }, [A, B], { ctx, fetch: () => assert.fail("asked") }), [])
})

test("kinds from the type or the extension; filters; day groups keep order", () => {
  assert.equal(mediaType({ type: "image/gif" }), "gif")
  assert.equal(mediaType({ url: "https://x/y.GIF" }), "gif")
  assert.equal(mediaType({ type: "image/png" }), "photo")
  assert.equal(mediaType({ url: "https://x/y.mov?x=1" }), "video")
  assert.equal(mediaType({ type: "application/pdf", url: "https://x/y" }), "other")
  assert.ok(TYPE_FILTERS.photos({ kind: "photo" }) && !TYPE_FILTERS.photos({ kind: "gif" }) && TYPE_FILTERS.all({ kind: "other" }))
  const day = 86400
  const g = byDay([{ uploaded: 10 * day + 5 }, { uploaded: 10 * day + 1 }, { uploaded: 9 * day }, { uploaded: 0 }], "en-US")
  assert.deepEqual(g.map(x => x.blobs.length), [2, 1, 1])
  assert.equal(g.at(-1).day, "Undated")
  const t = blossomAuthTemplate("delete", H("d"), 1000)
  assert.deepEqual(t.tags, [["t", "delete"], ["x", H("d")], ["expiration", "1600"]])
})

test("Test: a file of yours the server still serves proves it works; gone, empty, or silent say so", async () => {
  const { testServer, SERVER_STATES } = await import("../src/net/blossom-gallery.js")
  const list = [{ sha256: H("9"), url: `${A}/${H("9")}`, uploaded: 5 }]
  const make = ({ listed = list, head = 200, listFails = false, front = true }) => async (url, opt = {}) => {
    if (url.includes("/list/")) { if (listFails) throw new TypeError("Failed to fetch"); return res(200, listed) }
    if (opt.method === "HEAD") { assert.equal(url, `${A}/${H("9")}`); return res(head) }
    if (!front) throw new TypeError("Failed to fetch")
    assert.equal(opt.mode, "no-cors"); return { ok: false, status: 0, type: "opaque" }
  }
  const ro = { ...ctx, signer: { readOnly: true } }
  assert.equal((await testServer(A, ME, { ctx: ro, fetch: make({}) })).state, "working")
  assert.equal((await testServer(A, ME, { ctx: ro, fetch: make({ head: 404 }) })).state, "lostFile")
  assert.equal((await testServer(A, ME, { ctx: ro, fetch: make({ listed: [] }) })).state, "answers")
  assert.deepEqual(await testServer(A, ME, { ctx: ro, fetch: make({ listFails: true }) }), { state: "answers", reason: "Failed to fetch" })
  assert.equal((await testServer(A, ME, { ctx: ro, fetch: make({ listFails: true, front: false }) })).state, "offline")
  assert.deepEqual(Object.keys(SERVER_STATES), ["working", "answers", "lostFile", "offline"])
})
