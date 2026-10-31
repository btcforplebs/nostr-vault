// Vault › Media: server lists merged by hash, a server that wants authorisation asked again with one signed "list"
// auth, delete and mirror scoped to the file's hash, and the kinds and day groups the grid shows. Throwaway keys and
// a fake fetch: no server is contacted.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { listBlobs, deleteBlob, deleteTargets, mirrorBlob, mediaType, byDay, outcome, blossomAuthTemplate, TYPE_FILTERS, resetListAuth } from "../src/net/blossom-gallery.js"

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

test("each server's list draws as it answers, without waiting for the slowest", async () => {
  resetListAuth()
  let release
  const slow = new Promise(r => { release = r })
  const parts = []
  const fetch = async url => url.startsWith(A) ? res(200, [{ sha256: H("1"), url: `${A}/${H("1")}`, uploaded: 1 }]) : (await slow, res(200, [{ sha256: H("2"), url: `${B}/${H("2")}`, uploaded: 2 }]))
  const done = listBlobs([A, B], ME, { ctx, fetch, on: p => parts.push(p) })
  await new Promise(r => setTimeout(r, 10))
  assert.deepEqual(parts.map(p => [p.blobs.map(b => b.sha256[0]), p.status]), [[["1"], { [A]: "ok" }]], "A's files show while B is still being asked")
  release()
  const r = await done
  assert.deepEqual(r.blobs.map(b => b.sha256[0]), ["2", "1"])
  assert.equal(parts.length, 2)
})

test("a server that wanted a signed list is asked signed straight away next time", async () => {
  resetListAuth()
  const calls = []
  const fetch = async (url, opt = {}) => { calls.push(opt.headers?.Authorization ? "auth" : "none"); if (!opt.headers?.Authorization) throw new TypeError("Failed to fetch"); return res(200, []) }
  await listBlobs([B], ME, { ctx, fetch })
  assert.deepEqual(calls, ["none", "auth"])
  calls.length = 0
  await listBlobs([B], ME, { ctx, fetch })
  assert.deepEqual(calls, ["auth"], "no unsigned try first")
  // A read-only account still asks unsigned: it can't sign.
  calls.length = 0
  await listBlobs([B], ME, { ctx: { ...ctx, signer: { readOnly: true } }, fetch })
  assert.deepEqual(calls, ["none"])
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
  // Each server gets its own token naming it, so none can be replayed against another (the home vault refuses that).
  assert.deepEqual(seen.map(s => s[2].tags.find(t => t[0] === "server")?.[1]), [A, B].map(s => new URL(s).hostname))
  const exp = Number(auth.tags.find(t => t[0] === "expiration")[1])
  assert.equal(exp - auth.created_at, 300, "a delete token lasts five minutes")
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
  // The phone's headings (MediaDateGrouping): Today, This Week (the calendar week), This Month, month, month and year.
  const now = new Date(2026, 9, 22, 15) // Thursday 22 October 2026
  const at = (m, d, y = 2026) => new Date(y, m, d, 12).getTime() / 1000
  const g = byDay([{ uploaded: at(9, 22) }, { uploaded: at(9, 22) - 3600 }, { uploaded: at(9, 19) }, { uploaded: at(9, 18) }, { uploaded: at(9, 2) }, { uploaded: at(8, 30) }, { uploaded: at(11, 25, 2025) }, { uploaded: 0 }], "en-US", now)
  assert.deepEqual(g.map(x => [x.day, x.blobs.length]), [["Today", 2], ["This Week", 2], ["This Month", 1], ["September", 1], ["December 2025", 1], ["Undated", 1]])
  // A week that starts on Monday leaves Sunday the 18th in This Month.
  assert.deepEqual(byDay([{ uploaded: at(9, 19) }, { uploaded: at(9, 18) }], "en-GB", now).map(x => x.day), ["This Week", "This Month"])
  assert.deepEqual(blossomAuthTemplate("delete", H("d"), 1000, "vault.example").tags, [["t", "delete"], ["x", H("d")], ["server", "vault.example"], ["expiration", "1300"]])
  assert.deepEqual(blossomAuthTemplate("upload", H("d"), 1000).tags, [["t", "upload"], ["x", H("d")], ["expiration", "1600"]])
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

test("Delete from mirrors goes to every media server, any other that listed the file and the host in its link, once each", async () => {
  // The file's list showed it only on B; A and C are the account's servers (C's list missed it); D is in its link.
  const blob = { sha256: H("e"), url: `${D}/${H("e")}.jpg`, servers: [B] }
  assert.deepEqual(deleteTargets(blob, [A, C, `${B}/`]), [A, C, B, D])
  assert.deepEqual(deleteTargets({ ...blob, url: `${A}/${H("e")}` }, [A, C]), [A, C, B], "the link's host isn't asked twice")
  assert.deepEqual(deleteTargets({ ...blob, url: `http://evil.example/${H("e")}` }, [A]), [A, B], "only https (or this machine) hosts")
  assert.deepEqual(deleteTargets({ ...blob, url: "not a url" }, [A]), [A, B])
  const seen = []
  const r = await deleteBlob(blob, { ctx, servers: [A, C], fetch: async (url, opt) => { seen.push([url, opt.method, authOf(opt.headers.Authorization).tags[1]]); return url.startsWith(C) ? res(500, null, "busy") : res(url.startsWith(D) ? 404 : 200) } })
  assert.deepEqual(seen.map(x => x[0]), [A, C, B, D].map(s => `${s}/${H("e")}`))
  assert.ok(seen.every(x => x[1] === "DELETE" && x[2][1] === H("e")), "each delete auth is scoped to the file")
  assert.deepEqual(r.map(x => [x.server, x.ok]), [[A, true], [C, false], [B, true], [D, true]])
  assert.match(outcome(r, "Deleted"), /^Deleted on 3 of 4 servers\. c\.example: busy/)
})
